#!/usr/bin/env python3
"""
/usr/lib/porg/deps.py

Resolvedor de dependências do Porg (integra com porg_builder.sh e porg_logger.sh)

Funcionalidades:
- localizar metafile YAML de um pacote em /usr/ports/<categoria>/<pkg>/
- parsear metafile (usa PyYAML se disponível; fallback para parser simples)
- resolver dependências recursivamente (build_depends + depends)
- detectar ciclos e avisar
- cachear resultados em /var/cache/porg/deps_cache.json
- checar dependências instaladas via DB simples em /var/db/porg/installed.json
- integracao com logger shell: invoca porg_logger.sh via bash -c 'source ...; log INFO "...' para produzir logs coloridos
- modos CLI: resolve, check, missing, graph, register-installed, unregister-installed, cache-clear

Usage:
  python3 /usr/lib/porg/deps.py resolve gcc
  python3 /usr/lib/porg/deps.py missing gcc
  python3 /usr/lib/porg/deps.py check gcc
  python3 /usr/lib/porg/deps.py graph gcc
  python3 /usr/lib/porg/deps.py register-installed gcc-13.2.0
  python3 /usr/lib/porg/deps.py cache-clear

O builder deve chamar este resolvedor antes de iniciar o build,
por exemplo: python3 /usr/lib/porg/deps.py resolve gcc
"""

from __future__ import annotations
import sys
import os
import json
import subprocess
import argparse
import fnmatch
import time
from typing import Dict, List, Set, Tuple, Optional

# -------------------- Paths & defaults --------------------
PORG_CONF = os.environ.get("PORG_CONF", "/etc/porg/porg.conf")
DEFAULT_PORTS_DIR = "/usr/ports"
CACHE_DIR = os.environ.get("PORG_CACHE_DIR", "/var/cache/porg")
DEPS_CACHE = os.path.join(CACHE_DIR, "deps_cache.json")
DB_DIR = os.environ.get("PORG_DB_DIR", "/var/db/porg")
INSTALLED_DB = os.path.join(DB_DIR, "installed.json")
LOGGER_SCRIPT = os.environ.get("PORG_LOGGER", "/usr/lib/porg/porg_logger.sh")
LOG_DIR = os.environ.get("LOG_DIR", "/var/log/porg")  # fallback; porg.conf may override

# ensure dirs exist (may require privileges)
os.makedirs(CACHE_DIR, exist_ok=True)
os.makedirs(DB_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

# -------------------- Helper: call shell logger --------------------
def shell_log(level: str, message: str) -> None:
    """
    Call the shell logger by sourcing the porg_logger.sh and invoking log.
    This keeps log colorization and file session behavior centralized.
    """
    try:
        # Use bash -lc to source and call log; escape message safely
        safe = message.replace("'", "'\"'\"'")
        cmd = f"source '{LOGGER_SCRIPT}' >/dev/null 2>&1 || true; log {level} '{safe}'"
        subprocess.run(["bash", "-lc", cmd], check=False)
    except Exception:
        # best-effort; do not fail deps resolution because logging failed
        pass

# -------------------- Read porg.conf (simple KEY=VALUE parser) --------------------
def load_porg_conf(conf_path: str = PORG_CONF) -> Dict[str, str]:
    cfg = {}
    if not os.path.isfile(conf_path):
        return cfg
    try:
        with open(conf_path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    cfg[k] = v
    except Exception:
        pass
    return cfg

# Merge porg.conf overrides
_pconf = load_porg_conf()
PORTS_DIR = _pconf.get("PORTS_DIR", DEFAULT_PORTS_DIR)
LOG_DIR = _pconf.get("LOG_DIR", LOG_DIR)
CACHE_DIR = _pconf.get("CACHE_DIR", CACHE_DIR)
DEPS_CACHE = os.path.join(CACHE_DIR, "deps_cache.json")
INSTALLED_DB = os.path.join(DB_DIR, "installed.json")

# -------------------- YAML parsing --------------------
# Prefer PyYAML if available, else fallback to simple parser for our schema
try:
    import yaml  # type: ignore
    _HAS_YAML = True
except Exception:
    _HAS_YAML = False

def parse_metafile_yaml(path: str) -> Dict:
    """
    Parse the package metafile YAML and return a dict.
    Supports expected keys:
      name, version, depends (list), build_depends (list), sources, patches, hooks, stage, etc.
    """
    if not os.path.isfile(path):
        return {}
    if _HAS_YAML:
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f) or {}
                # normalize lists
                if isinstance(data.get("depends"), str):
                    data["depends"] = [data["depends"]]
                if isinstance(data.get("build_depends"), str):
                    data["build_depends"] = [data["build_depends"]]
                return data
        except Exception:
            pass
    # fallback simple parser: look for lines 'depends:' then following '- item'
    data = {}
    cur = None
    arr = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                stripped = line.lstrip()
                if not stripped or stripped.startswith("#"):
                    continue
                if ":" in stripped and not stripped.startswith("-"):
                    k, v = stripped.split(":", 1)
                    k = k.strip()
                    v = v.strip()
                    if v == "" or v in ("|", ">"):
                        cur = k
                        arr = []
                        data[k] = arr
                    else:
                        # scalar
                        data[k] = v.strip().strip('"').strip("'")
                        cur = None
                elif stripped.startswith("-") and cur:
                    item = stripped[1:].strip()
                    arr.append(item)
    except Exception:
        pass
    return data

# -------------------- Locate metafile --------------------
def find_metafile_for(pkg_name: str) -> Optional[str]:
    """
    Search PORTS_DIR for a metafile that corresponds to pkg_name.
    Expected location: /usr/ports/<cat>/<pkg>/<pkg>-<version>.yaml
    We'll search for files matching {pkg_name}*.y*ml under PORTS_DIR/*
    Returns the first match or None.
    """
    # look for directories named pkg_name first
    candidates = []
    # Walk two levels: PORTS_DIR/category/pkg/*
    if not os.path.isdir(PORTS_DIR):
        return None
    for cat in os.listdir(PORTS_DIR):
        cdir = os.path.join(PORTS_DIR, cat)
        if not os.path.isdir(cdir):
            continue
        pkgdir = os.path.join(cdir, pkg_name)
        if os.path.isdir(pkgdir):
            # find yaml files inside pkgdir
            for entry in os.listdir(pkgdir):
                if fnmatch.fnmatch(entry.lower(), f"{pkg_name}*.y*ml"):
                    candidates.append(os.path.join(pkgdir, entry))
            if candidates:
                return candidates[0]
    # fallback: global walk (could be slower)
    for root, dirs, files in os.walk(PORTS_DIR):
        for name in files:
            if fnmatch.fnmatch(name.lower(), f"{pkg_name}*.y*ml") or name.lower().startswith(f"{pkg_name}-"):
                candidates.append(os.path.join(root, name))
    if candidates:
        return candidates[0]
    return None

# -------------------- Installed DB helpers --------------------
def load_installed_db() -> Dict[str, Dict]:
    if os.path.isfile(INSTALLED_DB):
        try:
            with open(INSTALLED_DB, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_installed_db(dct: Dict) -> None:
    try:
        os.makedirs(os.path.dirname(INSTALLED_DB), exist_ok=True)
        with open(INSTALLED_DB, "w", encoding="utf-8") as f:
            json.dump(dct, f, indent=2, ensure_ascii=False)
    except Exception:
        pass

def is_installed(pkg_query: str) -> bool:
    """
    pkg_query may be 'pkg' or 'pkg-version'
    We'll consider installed if any installed entry starts with pkg_query or equals it.
    """
    db = load_installed_db()
    for key in db.keys():
        if key == pkg_query or key.startswith(pkg_query + "-") or key.startswith(pkg_query + "/"):
            return True
        # also support pkg without version
        if key.split("-")[0] == pkg_query:
            return True
    return False

# -------------------- Cache helpers --------------------
def load_cache() -> Dict[str, List[str]]:
    try:
        if os.path.isfile(DEPS_CACHE):
            with open(DEPS_CACHE, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass
    return {}

def save_cache(cache: Dict[str, List[str]]) -> None:
    try:
        os.makedirs(os.path.dirname(DEPS_CACHE), exist_ok=True)
        with open(DEPS_CACHE, "w", encoding="utf-8") as f:
            json.dump(cache, f, indent=2, ensure_ascii=False)
    except Exception:
        pass

# -------------------- Core: resolve dependencies --------------------
class DependencyResolver:
    def __init__(self):
        self.cache = load_cache()  # maps pkg_name -> resolved list
        self.visiting: Set[str] = set()
        self.resolved: Dict[str, List[str]] = {}  # memo
        self.cycles: List[List[str]] = []

    def _read_metafile_deps(self, pkg: str) -> Tuple[List[str], List[str]]:
        """
        Return (build_depends, depends) for pkg.
        If metafile not found, return empty lists.
        """
        mf = find_metafile_for(pkg)
        if not mf:
            shell_log("WARN", f"Metafile not found for package '{pkg}' (searched in {PORTS_DIR})")
            return ([], [])
        data = parse_metafile_yaml(mf)
        # keys may be 'build_depends', 'build-depends', 'depends', 'run_depends'
        build = []
        run = []
        for k, v in data.items():
            kl = k.lower()
            if kl in ("build_depends", "build-depends", "build-requires", "build_requires", "build_requires:"):
                if isinstance(v, list):
                    build = [str(x).strip() for x in v if x]
                elif isinstance(v, str):
                    build = [v.strip()]
            if kl in ("depends", "run_depends", "runtime_depends", "requires", "run-depends"):
                if isinstance(v, list):
                    run = [str(x).strip() for x in v if x]
                elif isinstance(v, str):
                    run = [v.strip()]
        # also accept 'depends' and 'build_depends' top-level common names
        # Some metafiles use 'dependencies' etc; we'll attempt a few more keys:
        if not build:
            for alt in ("build_requires", "build-requires"):
                if alt in data:
                    vv = data.get(alt, [])
                    build = vv if isinstance(vv, list) else [vv]
        if not run:
            for alt in ("runtime_requires", "runtime-depends", "requires"):
                if alt in data:
                    vv = data.get(alt, [])
                    run = vv if isinstance(vv, list) else [vv]
        # normalize: strip version qualifiers like pkg>=1.2 -> pkg
        build = [self._normalize_name(x) for x in build]
        run = [self._normalize_name(x) for x in run]
        return (build, run)

    def _normalize_name(self, s: str) -> str:
        # Remove parentheses, version specs, alternatives 'pkg (>= 1.2)', 'pkg>=1.2', 'pkg | other'
        if not s:
            return s
        # handle 'pkg@version' or 'pkg-version' keep base
        s = s.strip()
        # if contains space then take first token
        # remove things after whitespace or characters like >=, =, ( etc.
        for sep in [" ", ">=", "<=", "==", "=", "(", "[", "{", ";", ","]:
            if sep in s:
                s = s.split(sep, 1)[0]
        # if pipes alternatives, take first
        if "|" in s:
            s = s.split("|", 1)[0]
        return s.strip()

    def resolve(self, pkg: str) -> List[str]:
        """
        Return ordered list of packages to build (dependency order)
        If pkg is already cached, return cached.
        """
        if pkg in self.cache:
            shell_log("DEBUG", f"deps cache hit for {pkg}")
            return self.cache[pkg]

        self.visiting = set()
        order: List[str] = []
        visited: Set[str] = set()

        def dfs(node: str, stack: List[str]):
            if node in visited:
                return
            if node in stack:
                # found cycle
                cyc = stack[stack.index(node):] + [node]
                self.cycles.append(cyc)
                shell_log("ERROR", f"Dependency cycle detected: {' -> '.join(cyc)}")
                return
            stack.append(node)
            # read deps for node
            build_deps, run_deps = self._read_metafile_deps(node)
            # combine build_deps first, then run_deps (build deps are required to build this package)
            for dep in (build_deps + run_deps):
                if not dep:
                    continue
                # skip if already installed
                if is_installed(dep):
                    shell_log("DEBUG", f"Dependency {dep} already installed; skipping")
                    continue
                dfs(dep, stack)
            # after children
            stack.pop()
            if node not in visited:
                visited.add(node)
                order.append(node)

        dfs(pkg, [])
        # order is bottom-up; ensure pkg is at end; return order
        # Save to cache
        self.cache[pkg] = order
        save_cache(self.cache)
        return order

    def missing(self, pkg: str) -> List[str]:
        """
        Return list of dependencies (resolved) that are not installed.
        """
        resolved = self.resolve(pkg)
        missing = [p for p in resolved if not is_installed(p)]
        return missing

    def check(self, pkg: str) -> bool:
        """
        Return True if all deps are installed.
        """
        m = self.missing(pkg)
        return len(m) == 0

    def graph(self, pkg: str) -> str:
        """
        Return a simple textual graph representation (one edge per line: A -> B)
        """
        visited = set()
        edges = []

        def dfs_edges(node: str):
            if node in visited:
                return
            visited.add(node)
            build_deps, run_deps = self._read_metafile_deps(node)
            for dep in (build_deps + run_deps):
                if not dep:
                    continue
                edges.append(f"{node} -> {dep}")
                dfs_edges(dep)

        dfs_edges(pkg)
        return "\n".join(edges)

# -------------------- CLI --------------------
def parse_args(argv):
    p = argparse.ArgumentParser(prog="porg-deps", description="Porg dependency resolver")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("cache-clear", help="Clear deps cache")
    sub_res = sub.add_parser("resolve", help="Resolve dependency list for a package")
    sub_res.add_argument("pkg")
    sub_miss = sub.add_parser("missing", help="List missing dependencies (not installed)")
    sub_miss.add_argument("pkg")
    sub_check = sub.add_parser("check", help="Check if all dependencies are installed")
    sub_check.add_argument("pkg")
    sub_graph = sub.add_parser("graph", help="Print dependency graph")
    sub_graph.add_argument("pkg")
    sub_reg = sub.add_parser("register-installed", help="Register package as installed")
    sub_reg.add_argument("pkgid")  # e.g., gcc-13.2.0
    sub_unreg = sub.add_parser("unregister-installed", help="Remove package from installed DB")
    sub_unreg.add_argument("pkgid")
    sub_list = sub.add_parser("list-installed", help="List installed packages")
    return p.parse_args(argv)

def main(argv):
    args = parse_args(argv)
    dr = DependencyResolver()

    if args.cmd == "cache-clear":
        try:
            if os.path.isfile(DEPS_CACHE):
                os.remove(DEPS_CACHE)
            shell_log("INFO", "Deps cache cleared")
            print("OK")
        except Exception as e:
            shell_log("ERROR", f"Failed to clear deps cache: {e}")
            print("ERROR", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)

    if args.cmd == "resolve":
        pkg = args.pkg
        shell_log("INFO", f"Resolving dependencies for {pkg}")
        try:
            order = dr.resolve(pkg)
            # output JSON list
            out = {"package": pkg, "order": order, "cycles": dr.cycles}
            print(json.dumps(out, ensure_ascii=False))
            shell_log("INFO", f"Resolved {len(order)} items for {pkg}")
            sys.exit(0)
        except Exception as e:
            shell_log("ERROR", f"Error resolving {pkg}: {e}")
            print(json.dumps({"error": str(e)}))
            sys.exit(1)

    if args.cmd == "missing":
        pkg = args.pkg
        shell_log("INFO", f"Checking missing dependencies for {pkg}")
        try:
            missing = dr.missing(pkg)
            print(json.dumps({"package": pkg, "missing": missing}, ensure_ascii=False))
            if missing:
                shell_log("WARN", f"Missing deps for {pkg}: {', '.join(missing)}")
            else:
                shell_log("INFO", f"All deps satisfied for {pkg}")
            sys.exit(0)
        except Exception as e:
            shell_log("ERROR", f"Error checking missing deps for {pkg}: {e}")
            print(json.dumps({"error": str(e)}))
            sys.exit(1)

    if args.cmd == "check":
        pkg = args.pkg
        ok = dr.check(pkg)
        print(json.dumps({"package": pkg, "ok": ok}))
        if ok:
            shell_log("INFO", f"Dependencies satisfied for {pkg}")
        else:
            shell_log("WARN", f"Dependencies NOT satisfied for {pkg}")
        sys.exit(0)

    if args.cmd == "graph":
        pkg = args.pkg
        shell_log("INFO", f"Generating dependency graph for {pkg}")
        g = dr.graph(pkg)
        print(g)
        # also log a brief summary
        shell_log("DEBUG", f"Graph for {pkg} generated with {len(g.splitlines())} edges")
        sys.exit(0)

    if args.cmd == "register-installed":
        pkgid = args.pkgid
        db = load_installed_db()
        db[pkgid] = {"installed_at": time.time()}
        save_installed_db(db)
        shell_log("INFO", f"Registered installed package: {pkgid}")
        print("OK")
        sys.exit(0)

    if args.cmd == "unregister-installed":
        pkgid = args.pkgid
        db = load_installed_db()
        if pkgid in db:
            db.pop(pkgid, None)
            save_installed_db(db)
            shell_log("INFO", f"Unregistered installed package: {pkgid}")
            print("OK")
        else:
            shell_log("WARN", f"Package not found in installed DB: {pkgid}")
            print("NOTFOUND")
        sys.exit(0)

    if args.cmd == "list-installed":
        db = load_installed_db()
        print(json.dumps({"installed": list(db.keys())}, ensure_ascii=False))
        shell_log("DEBUG", f"Listed {len(db)} installed packages")
        sys.exit(0)

    # fallback
    print("Unknown command", file=sys.stderr)
    sys.exit(2)

if __name__ == "__main__":
    main(sys.argv[1:])

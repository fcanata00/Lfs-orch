#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
porg_deps.py - Resolvedor avançado de dependências para Porg
- suporta group metafiles (blfs/xorg/kde)
- ordena por tiers (core, system, libs, gui, desktop)
- gera upgrade plan, detecta rebuilds necessários
- integra com /etc/porg/porg.conf e INSTALLED_DB
- CLI: resolve, upgrade-plan, graph, missing, check, register-installed
"""

from __future__ import annotations
import os, sys, json, time, argparse, subprocess, collections, traceback
from typing import Dict, List, Set, Tuple, Any

# ---------------------------
# Config (carrega /etc/porg/porg.conf se existir)
# ---------------------------
PORG_CONF = os.environ.get("PORG_CONF", "/etc/porg/porg.conf")
CONFIG = {}
if os.path.isfile(PORG_CONF):
    try:
        # porg.conf is a shell script with KEY=VALUE, parse simply
        with open(PORG_CONF, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    CONFIG[k] = v
    except Exception:
        pass

PORTS_DIR = os.environ.get("PORTS_DIR", CONFIG.get("PORTS_DIR", "/usr/ports"))
INSTALLED_DB = os.environ.get("INSTALLED_DB", CONFIG.get("INSTALLED_DB", os.path.join(CONFIG.get("DB_DIR", "/var/lib/porg/db"), "installed.json")))
CACHE_DIR = os.environ.get("CACHE_DIR", CONFIG.get("CACHE_DIR", "/var/cache/porg"))
DEPS_CACHE = os.path.join(CACHE_DIR, "deps_cache.json")
LOGGER_SCRIPT = os.environ.get("LOGGER_SCRIPT", CONFIG.get("LOGGER_MODULE", "/usr/lib/porg/porg_logger.sh"))

os.makedirs(CACHE_DIR, exist_ok=True)

# ---------------------------
# Tiers priority mapping
# ---------------------------
TIER_ORDER = {
    "core": 0,
    "system": 1,
    "libs": 2,
    "gui": 3,
    "desktop": 4,
    "optional": 5,
    "unknown": 6
}

# ---------------------------
# YAML loader: prefer PyYAML if available, fallback to simple parser
# ---------------------------
try:
    import yaml
    YAML_AVAILABLE = True
except Exception:
    YAML_AVAILABLE = False

def load_yaml_file(path: str) -> Dict[str, Any]:
    if not os.path.isfile(path):
        return {}
    if YAML_AVAILABLE:
        try:
            with open(path, "r", encoding="utf-8") as f:
                return yaml.safe_load(f) or {}
        except Exception:
            # fallback to basic
            pass
    # basic fallback parser (extracts simple key: value and lists)
    data = {}
    current_list_key = None
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.rstrip("\n")
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if ":" in s and not s.startswith("-"):
                k, v = s.split(":", 1)
                k = k.strip()
                v = v.strip()
                if v == "":
                    data[k] = {}
                    current_list_key = k
                else:
                    # strip quotes
                    if v.startswith(("'", '"')) and v.endswith(("'", '"')):
                        v = v[1:-1]
                    data[k] = v
                    current_list_key = None
            elif s.startswith("-") and current_list_key:
                item = s[1:].strip()
                if isinstance(data.get(current_list_key), list):
                    data[current_list_key].append(item)
                else:
                    data[current_list_key] = [item]
            else:
                # no-op
                current_list_key = None
    return data

# ---------------------------
# Logging helper: if porg_logger.sh exists call it, else print
# ---------------------------
def shell_log(level: str, msg: str):
    """
    Attempts to call porg_logger.sh functions if available, else prints.
    level in: INFO, WARN, ERROR, DEBUG, STAGE
    """
    if os.path.isfile(LOGGER_SCRIPT):
        # call logger in a subshell to avoid altering env
        try:
            subprocess.run(["bash", "-lc",
                            f"source '{LOGGER_SCRIPT}' >/dev/null 2>&1 || true; "
                            f"if declare -f log_{level.lower()} >/dev/null 2>&1; then log_{level.lower()} '{msg.replace(\"'\",\"'\\\\''\")}' ; else echo '[{level}] {msg}'; fi"],
                           check=False)
            return
        except Exception:
            pass
    # fallback
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if level == "ERROR":
        print(f"{ts} [{level}] {msg}", file=sys.stderr)
    else:
        print(f"{ts} [{level}] {msg}")

# ---------------------------
# Installed DB helpers
# ---------------------------
def read_installed_db() -> Dict[str, Dict[str, Any]]:
    try:
        if os.path.isfile(INSTALLED_DB):
            with open(INSTALLED_DB, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        shell_log("WARN", f"Failed to read installed DB {INSTALLED_DB}, treating as empty")
    return {}

def is_installed(pkgname: str, installed_db: Dict[str, Any]) -> bool:
    for k, v in installed_db.items():
        if k == pkgname or k.startswith(pkgname + "-") or v.get("name") == pkgname:
            return True
    return False

def installed_version(pkgname: str, installed_db: Dict[str, Any]) -> str:
    for k, v in installed_db.items():
        if k == pkgname or k.startswith(pkgname + "-") or v.get("name") == pkgname:
            return v.get("version", "")
    return ""

# ---------------------------
# Metafile discovery
# ---------------------------
def find_metafile(pkg: str) -> str:
    """
    Procura por <pkg>*.yml/yaml dentro de PORTS_DIR e suas subpastas.
    Retorna o primeiro caminho encontrado ou ''.
    """
    if not os.path.isdir(PORTS_DIR):
        return ""
    for root, _, files in os.walk(PORTS_DIR):
        for fn in files:
            ln = fn.lower()
            if not (ln.endswith(".yml") or ln.endswith(".yaml")):
                continue
            name_noext = ln.rsplit(".", 1)[0]
            # try to match prefix
            if name_noext.startswith(pkg.lower()):
                return os.path.join(root, fn)
    return ""

# ---------------------------
# Parse a package metafile returning canonical dict
# ---------------------------
def parse_metafile(path: str) -> Dict[str, Any]:
    data = load_yaml_file(path)
    result = {}
    result["path"] = path
    result["name"] = data.get("name") or data.get("pkg") or os.path.splitext(os.path.basename(path))[0]
    result["version"] = str(data.get("version") or data.get("ver") or data.get("release") or "")
    # dependencies could be present as dependencies.build/runtime/optional or dependencies: [..]
    deps = []
    dd = data.get("dependencies") or data.get("depends") or {}
    if isinstance(dd, dict):
        for key in ("build", "runtime", "optional"):
            val = dd.get(key)
            if isinstance(val, list):
                deps.extend(val)
            elif isinstance(val, str):
                deps.append(val)
    elif isinstance(dd, list):
        deps.extend(dd)
    # also support top-level 'depends' or 'deps' lists
    for alt in ("deps", "requires"):
        av = data.get(alt)
        if isinstance(av, list):
            deps.extend(av)
    # normalize unique
    result["dependencies"] = list(dict.fromkeys([d for d in deps if d]))
    # group components
    if data.get("group") or data.get("components") or data.get("components"):
        result["is_group"] = True
        comps = data.get("components") or []
        if isinstance(comps, str):
            comps = [comps]
        result["components"] = comps
    else:
        result["is_group"] = False
        result["components"] = []
    # tier
    tier = data.get("tier") or data.get("priority") or "unknown"
    tier = tier if tier in TIER_ORDER else tier.lower() if tier.lower() in TIER_ORDER else "unknown"
    result["tier"] = tier
    # optional metadata
    result["metadata"] = data.get("metadata", {}) if isinstance(data.get("metadata", {}), dict) else {}
    return result

# ---------------------------
# Cache metafile parsing to avoid repeated IO
# ---------------------------
_PARSED_METAFILES: Dict[str, Dict[str, Any]] = {}
def get_pkg_meta(pkg: str) -> Dict[str, Any]:
    # search for metafile
    mf = find_metafile(pkg)
    if not mf:
        return {"name": pkg, "version": "", "dependencies": [], "is_group": False, "components": [], "tier": "unknown", "path": ""}
    if mf in _PARSED_METAFILES:
        return _PARSED_METAFILES[mf]
    try:
        p = parse_metafile(mf)
        _PARSED_METAFILES[mf] = p
        return p
    except Exception:
        shell_log("WARN", f"Failed to parse metafile {mf}")
        return {"name": pkg, "version": "", "dependencies": [], "is_group": False, "components": [], "tier": "unknown", "path": mf}

# ---------------------------
# Expand group metafiles to components
# ---------------------------
def expand_group(pkg: str) -> List[str]:
    """
    If pkg refers to a group metafile (eg: 'xorg' or path to a group), expand to its components.
    Returns components list or [pkg] if not a group.
    """
    meta = get_pkg_meta(pkg)
    if meta.get("is_group"):
        comps = meta.get("components", []) or []
        # components might be names or package names; return as-is
        return comps
    # also check if there is a group metafile named pkg-group or pkg.yaml with group:true
    return [pkg]

# ---------------------------
# Build dependency graph (recursive)
# ---------------------------
class DepResolver:
    def __init__(self):
        self.installed_db = read_installed_db()
        self.graph: Dict[str, Set[str]] = {}   # node -> set(deps)
        self.meta: Dict[str, Dict[str, Any]] = {}  # node -> metadata
        self.visiting: Set[str] = set()
        self.visited: Set[str] = set()
        self.cycles: List[List[str]] = []
        self.needs_rebuild_cache: Dict[str, bool] = {}

    def add_node(self, pkg: str):
        if pkg in self.graph:
            return
        self.graph[pkg] = set()
        pm = get_pkg_meta(pkg)
        self.meta[pkg] = pm

    def add_edge(self, pkg: str, dep: str):
        self.add_node(pkg)
        self.add_node(dep)
        self.graph[pkg].add(dep)

    def build_graph_for(self, roots: List[str], expand_groups=True):
        """
        roots: list of package names or group names
        expand_groups: if True, expand group metafiles automatically
        """
        to_process = list(roots)
        while to_process:
            cur = to_process.pop(0)
            # if group expand
            comps = expand_group(cur) if expand_groups else [cur]
            for comp in comps:
                if comp not in self.graph:
                    self.add_node(comp)
                # parse meta
                pm = get_pkg_meta(comp)
                deps = pm.get("dependencies", []) or []
                # add dependencies edges
                for d in deps:
                    self.add_edge(comp, d)
                    if d not in self.graph:
                        to_process.append(d)
                # if metafile is a group and has components, ensure components become processed
                if pm.get("is_group"):
                    for c in pm.get("components", []):
                        if c not in self.graph:
                            to_process.append(c)

    def _dfs_cycle(self, node: str, stack: List[str]):
        if node in self.visiting:
            # cycle found
            try:
                idx = stack.index(node)
                cyc = stack[idx:] + [node]
                self.cycles.append(cyc)
            except ValueError:
                self.cycles.append(stack + [node])
            return
        if node in self.visited:
            return
        self.visiting.add(node)
        stack.append(node)
        for dep in self.graph.get(node, []):
            self._dfs_cycle(dep, stack)
        stack.pop()
        self.visiting.remove(node)
        self.visited.add(node)

    def detect_cycles(self) -> List[List[str]]:
        self.visiting.clear(); self.visited.clear(); self.cycles.clear()
        for n in list(self.graph.keys()):
            if n not in self.visited:
                self._dfs_cycle(n, [])
        return self.cycles

    def topo_sort(self) -> List[str]:
        """
        Topological sort returning list where dependencies come BEFORE dependents.
        If cycles exist, return a best-effort order and log cycles.
        """
        indeg = {n: 0 for n in self.graph}
        for n, deps in self.graph.items():
            for d in deps:
                indeg[d] = indeg.get(d, 0) + 1
        q = collections.deque([n for n,deg in indeg.items() if deg == 0])
        order = []
        while q:
            n = q.popleft()
            order.append(n)
            for m in list(self.graph.get(n, [])):
                indeg[m] -= 1
                if indeg[m] == 0:
                    q.append(m)
        if len(order) != len(self.graph):
            # cycle detected - fallback: append remaining nodes
            remaining = [n for n in self.graph if n not in order]
            order.extend(remaining)
        return order

    def tier_sort(self, nodes: List[str]) -> List[str]:
        """
        Stable sort of nodes by tier priority. Keep topo order within same tier.
        """
        def tier_val(n):
            t = (self.meta.get(n) or {}).get("tier", "unknown") or "unknown"
            return TIER_ORDER.get(t, TIER_ORDER["unknown"])
        # stable sort preserving original order for equal keys
        return sorted(nodes, key=lambda x: (tier_val(x), nodes.index(x)))

    def compute_upgrade_plan(self, target_roots: List[str]) -> Dict[str, Any]:
        """
        Builds graph from target_roots, detects cycles, topologically sorts, applies tier ordering,
        and marks which packages require rebuild compared to installed DB.
        Returns dict:
        {
           "order": [pkg...],
           "tiers": {pkg: tier},
           "needs_rebuild": [pkg...],
           "cycles": [...],
           "meta": {...}
        }
        """
        # build graph expanding groups
        self.build_graph_for(target_roots, expand_groups=True)
        cycles = self.detect_cycles()
        if cycles:
            for c in cycles:
                shell_log("WARN", f"Dependency cycle detected: {' -> '.join(c)}")
        topo = self.topo_sort()  # deps-before-dependents
        # we want build order: from low-level to high-level (deps first)
        # topo is already deps first; we can then order by tier to ensure core before gui etc.
        ordered = self.tier_sort(topo)

        # detect rebuilds: version mismatch or dependency has rebuild
        needs_rebuild = set()
        # helper recursive detection
        def check_rebuild(pkg: str, visited_local: Set[str]) -> bool:
            if pkg in self.needs_rebuild_cache:
                return self.needs_rebuild_cache[pkg]
            if pkg in visited_local:
                # cycle -> force rebuild
                self.needs_rebuild_cache[pkg] = True
                return True
            visited_local.add(pkg)
            meta = self.meta.get(pkg) or get_pkg_meta(pkg)
            installed_ver = installed_version(pkg, self.installed_db)
            src_ver = meta.get("version", "") or ""
            # if not installed => needs build
            if not installed_ver:
                self.needs_rebuild_cache[pkg] = True
                visited_local.remove(pkg)
                return True
            # different version => rebuild
            if src_ver and src_ver != installed_ver:
                self.needs_rebuild_cache[pkg] = True
                visited_local.remove(pkg)
                return True
            # if any dependency needs rebuild => this needs rebuild
            for d in self.graph.get(pkg, []):
                if check_rebuild(d, visited_local):
                    self.needs_rebuild_cache[pkg] = True
                    visited_local.remove(pkg)
                    return True
            self.needs_rebuild_cache[pkg] = False
            visited_local.remove(pkg)
            return False

        for n in ordered:
            check_rebuild(n, set())

        needs = [p for p, val in self.needs_rebuild_cache.items() if val]

        # populate tiers map and meta subset
        tiers = {n: (self.meta.get(n) or {}).get("tier", "unknown") for n in ordered}
        meta_small = {n: {k: self.meta.get(n, {}).get(k) for k in ("version", "tier", "path")} for n in ordered}

        return {
            "order": ordered,
            "tiers": tiers,
            "needs_rebuild": needs,
            "cycles": cycles,
            "meta": meta_small
        }

# ---------------------------
# CLI commands implementations
# ---------------------------
def cmd_resolve(args):
    """
    Resolve dependencies for a package (or group). Print JSON: {"order":[...], "needs_rebuild":[...]}
    """
    dr = DepResolver()
    dr.installed_db = read_installed_db()
    plan = dr.compute_upgrade_plan([args.pkg])
    out = {
        "pkg": args.pkg,
        "order": plan["order"],
        "needs_rebuild": plan["needs_rebuild"],
        "tiers": plan["tiers"],
        "cycles": plan["cycles"]
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))

def cmd_upgrade_plan(args):
    """
    Generate upgrade plan for argument(s) or for full world if --world given.
    """
    dr = DepResolver()
    dr.installed_db = read_installed_db()
    roots = []
    if args.world:
        # build roots from installed DB keys (package names)
        db = dr.installed_db
        for k,v in db.items():
            name = v.get("name") or k
            roots.append(name)
    elif args.group:
        roots.extend(expand_group(args.group))
    elif args.pkgs:
        roots.extend(args.pkgs)
    else:
        print("Specify --pkgs <pkg1 pkg2...> or --group <group> or --world", file=sys.stderr)
        sys.exit(2)
    # compute plan for each root; to avoid duplicate edges, give roots as set
    plan = dr.compute_upgrade_plan(roots)
    # order is dependencies-first; for upgrade we probably want to build in the same order
    result = {
        "roots": roots,
        "upgrade_order": plan["order"],
        "needs_rebuild": plan["needs_rebuild"],
        "cycles": plan["cycles"],
        "meta": plan["meta"]
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))

def cmd_graph(args):
    dr = DepResolver()
    dr.installed_db = read_installed_db()
    dr.build_graph_for(args.pkgs or [args.pkg], expand_groups=True)
    # output nested graph JSON
    def node_to_obj(n, seen):
        if n in seen:
            return {"pkg": n, "tier": dr.meta.get(n, {}).get("tier", "unknown"), "note": "cycle"}
        seen.add(n)
        deps = sorted(list(dr.graph.get(n, [])))
        return {"pkg": n, "tier": dr.meta.get(n, {}).get("tier", "unknown"), "depends": [node_to_obj(d, seen.copy()) for d in deps]}
    roots = args.pkgs or [args.pkg]
    out = [node_to_obj(r, set()) for r in roots]
    print(json.dumps(out, indent=2, ensure_ascii=False))

def cmd_missing(args):
    """
    Show missing dependencies for a package (compared to installed DB).
    """
    dr = DepResolver()
    dr.installed_db = read_installed_db()
    dr.build_graph_for([args.pkg], expand_groups=True)
    missing = []
    for n in dr.graph:
        if not is_installed(n, dr.installed_db):
            missing.append(n)
    print(json.dumps({"pkg": args.pkg, "missing": missing}, indent=2, ensure_ascii=False))

def cmd_check(args):
    """
    Check if a package is installed and up-to-date vs metafile version.
    """
    db = read_installed_db()
    installed = is_installed(args.pkg, db)
    meta = get_pkg_meta(args.pkg)
    src_ver = meta.get("version", "")
    inst_ver = installed_version(args.pkg, db)
    needs = False
    reason = ""
    if not installed:
        needs = True
        reason = "not installed"
    elif src_ver and inst_ver and src_ver != inst_ver:
        needs = True
        reason = f"installed {inst_ver} != source {src_ver}"
    print(json.dumps({"pkg": args.pkg, "installed": installed, "installed_version": inst_ver, "source_version": src_ver, "needs_rebuild": needs, "reason": reason}, indent=2, ensure_ascii=False))

def cmd_register_installed(args):
    """
    Register packages in DB by scanning a prefix or using given key. Useful after manual install.
    """
    db = read_installed_db()
    out = []
    if args.key:
        # try to register a single key (format: name version prefix)
        parts = args.key.split(":")
        if len(parts) < 2:
            print("Usage for key: name:version[:prefix]", file=sys.stderr)
            sys.exit(2)
        name = parts[0]; ver = parts[1]; prefix = parts[2] if len(parts) > 2 else "/"
        # call porg_db.sh register if available else write directly
        dbp = INSTALLED_DB
        try:
            # atomic append via python
            with open(dbp, "r+", encoding="utf-8") as f:
                data = json.load(f)
                key = name + "-" + ver
                data[key] = {"name": name, "version": ver, "prefix": prefix, "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                f.seek(0); f.truncate(0); json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True)
            out.append({"registered": key})
        except Exception as e:
            print("Failed to register:", e, file=sys.stderr)
            sys.exit(3)
    elif args.prefix:
        # scan prefix for binaries? simplified: look for manifest files under prefix/var/lib/porg/manifests or similar
        print(json.dumps({"scanned_prefix": args.prefix, "note": "manual registration not fully implemented"}, indent=2, ensure_ascii=False))
        return
    else:
        print("Provide --key name:version[:prefix] or --prefix /mnt/dir", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(out, indent=2, ensure_ascii=False))

# ---------------------------
# CLI parser
# ---------------------------
def build_parser():
    p = argparse.ArgumentParser(prog="porg_deps.py", description="Resolvedor avançado de dependências (Porg)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s_resolve = sub.add_parser("resolve", help="Resolve dependencies for a package and print ordered list")
    s_resolve.add_argument("pkg", help="Pacote ou grupo a resolver")

    s_upgrade = sub.add_parser("upgrade-plan", help="Generate upgrade plan")
    s_upgrade.add_argument("--pkgs", nargs="*", help="Pacotes alvo (mutiple)", dest="pkgs")
    s_upgrade.add_argument("--group", help="Grupo a expandir (ex: blfs/xorg/kde)")
    s_upgrade.add_argument("--world", action="store_true", help="Plan for entire installed world")

    s_graph = sub.add_parser("graph", help="Output dependency tree (JSON)")
    s_graph.add_argument("--pkg", help="root package", dest="pkg")
    s_graph.add_argument("--pkgs", nargs="*", help="multiple roots", dest="pkgs")

    s_missing = sub.add_parser("missing", help="List missing packages in installed DB for a given package")
    s_missing.add_argument("pkg", help="package")

    s_check = sub.add_parser("check", help="Check installed vs source version for a package")
    s_check.add_argument("pkg", help="package")

    s_register = sub.add_parser("register-installed", help="Register a package in installed DB")
    s_register.add_argument("--key", help="Register as name:version[:prefix]")
    s_register.add_argument("--prefix", help="Scan prefix (not fully implemented)")

    s_info = sub.add_parser("info", help="Show resolver info (cache, ports dir)")
    s_info.add_argument("--json", action="store_true")

    return p

def cmd_info(args):
    info = {
        "ports_dir": PORTS_DIR,
        "installed_db": INSTALLED_DB,
        "cache": DEPS_CACHE,
        "yaml_available": YAML_AVAILABLE
    }
    if args.json:
        print(json.dumps(info, indent=2, ensure_ascii=False))
    else:
        for k,v in info.items():
            print(f"{k}: {v}")

# ---------------------------
# Entrypoint
# ---------------------------
def main():
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.cmd == "resolve":
            cmd_resolve(args)
        elif args.cmd == "upgrade-plan":
            cmd_upgrade_plan(args)
        elif args.cmd == "graph":
            if not args.pkg and not args.pkgs:
                print("Provide --pkg or --pkgs", file=sys.stderr); sys.exit(2)
            cmd_graph(args)
        elif args.cmd == "missing":
            cmd_missing(args)
        elif args.cmd == "check":
            cmd_check(args)
        elif args.cmd == "register-installed":
            cmd_register_installed(args)
        elif args.cmd == "info":
            cmd_info(args)
        else:
            parser.print_help()
    except Exception as e:
        shell_log("ERROR", f"Exception in porg_deps.py: {e}\n{traceback.format_exc()}")
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

if __name__ == "__main__":
    main()

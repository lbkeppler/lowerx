# Lê o NGenuity2Helper.exe decompilado (ilspycmd) e extrai os IDs USB e modelos.
# Uso: python3 -I extract_catalog.py <helper decompilado> catalog.json
import re, sys, os, glob, json
root = sys.argv[1]
center = open(os.path.join(root, 'NGenuity2.Devices/HyperXCenter.cs')).read().splitlines()
start = next(i for i, l in enumerate(center) if 'public void AddDevice(string id)' in l)
# blocos: cada IsCultureInvariantMatch até o próximo
rules = []
stop = next(i for i in range(start + 1, len(center)) if re.match(r'^\t(public|private|protected|internal) ', center[i]))
idxs = [i for i in range(start, stop) if 'IsCultureInvariantMatch(id' in center[i] and '!NGenuity2' not in center[i]]
for k, i in enumerate(idxs):
    end = idxs[k + 1] if k + 1 < len(idxs) else min(i + 80, stop)
    block = '\n'.join(center[i:end])
    ids = re.findall(r'"HID#VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})([^"]*)"', center[i])
    cls = (re.search(r'AddDevice[A-Za-z]*<([A-Z][A-Za-z0-9]+)>\(', block)
           or re.search(r'new (?!HyperXDevice\b)([A-Z][A-Za-z0-9]+)\(\)', block))
    special = re.search(r'\b(Add[A-Za-z0-9]+Endpoint)\(id', block)
    if not cls and special and special.group(1) == 'AddMousePulsefireHaste2WirelessEndpoint':
        cls = re.search(r'(MousePulsefireHaste2Wireless)', 'MousePulsefireHaste2Wireless')
    head = '\n'.join(center[i:i+3])
    dfu = 'DFUEndpoint' in head or 'inDFUmode: true' in head
    rules.append(dict(ids=ids, cls=cls.group(1) if cls else None, special=special.group(1) if special else None, dfu=dfu, line=i + 1))
# classe -> modelo
cls_model = {}
for f in glob.glob(os.path.join(root, '**/*.cs'), recursive=True):
    t = open(f, errors='ignore').read()
    name = os.path.splitext(os.path.basename(f))[0]
    mm = re.search(r'base\.Model = HyperXDeviceModel\.([A-Za-z0-9_]+);', t) or re.search(r'Model = HyperXDeviceModel\.([A-Za-z0-9_]+);', t)
    if mm and re.search(r'class ' + re.escape(name) + r'\b', t): cls_model[name] = mm.group(1)
# modelo -> título
utils = open(os.path.join(root, 'NGenuity2.Devices/HyperXDeviceUtils.cs')).read()
def table(func, prefix=''):
  out = {}
  fn = re.search(r'public static string ' + func + r'\(HyperXDeviceModel[^)]*\)(.*?)\n\t}', utils, re.S)
  if fn:
    pending = []
    for line in fn.group(1).splitlines():
        c = re.search(r'case HyperXDeviceModel\.([A-Za-z0-9_]+):', line)
        r = re.search(r'return "([^"]+)";', line)
        if c: pending.append(c.group(1))
        if r and pending:
            for p in pending: out[p] = prefix + r.group(1)
            pending = []
  return out
titles = table('GetShortDeviceTitle', 'HyperX ')
titles.update(table('GetDeviceTitleByModel'))
json.dump(dict(rules=rules, cls_model=cls_model, titles=titles), open(sys.argv[2], 'w'), indent=1)
print('regras', len(rules), 'classes', len(cls_model), 'títulos', len(titles))
print('sem classe:', [(r['line'], r['ids'][:1], r['special']) for r in rules if not r['cls']][:20])

"""Gera Sources/LowerX/DeviceCatalog.swift a partir do catalog.json do extract_catalog.py.

Uso:
  python3 -I extract_catalog.py <helper decompilado> catalog.json
  python3 -I gen_catalog_swift.py catalog.json <saída.swift>
"""
import json, re, sys

d = json.load(open(sys.argv[1]))
cls_model, titles = d['cls_model'], d['titles']

# Subclasses que herdam o modelo da classe-mãe.
cls_model.setdefault('MicrophoneQuadCastS2S', cls_model.get('MicrophoneQuadCastS'))
cls_model.setdefault('MicrophoneQuadCastSWhite', cls_model.get('MicrophoneQuadCastS'))
cls_model.setdefault('MicrophoneQuadCastSWhite2S', cls_model.get('MicrophoneQuadCastS'))

# Modelos "Universal" informam o nome pelo próprio aparelho; aqui vai o nome comercial.
manual = {
    'Headset_CloudFlight2': 'HyperX Cloud Flight 2',
    'UniversalKeyboardAlloyRise': 'HyperX Alloy Rise',
    'UniversalKeyboardAlloyRise75': 'HyperX Alloy Rise 75',
    'UniversalKeyboardAlloyRise75Wireless': 'HyperX Alloy Rise 75 Wireless',
    'UniversalMousePulsefireFuseWireless': 'HyperX Pulsefire Fuse Wireless',
    'UniversalMousePulsefireHaste2': 'HyperX Pulsefire Haste 2',
    'UniversalMousePulsefireHaste2CoreWireless': 'HyperX Pulsefire Haste 2 Core Wireless',
    'UniversalMousePulsefireHaste2MiniWireless': 'HyperX Pulsefire Haste 2 Mini Wireless',
    'UniversalMousePulsefireHaste2Pro': 'HyperX Pulsefire Haste 2 Pro',
    'UniversalMousePulsefireHaste2SWireless': 'HyperX Pulsefire Haste 2 S Wireless',
    'UniversalMousePulsefireHaste2Wireless': 'HyperX Pulsefire Haste 2 Wireless',
    'UniversalMousePulsefireSaga': 'HyperX Pulsefire Saga',
    'UniversalMousePulsefireSagaPro': 'HyperX Pulsefire Saga Pro',
    'UniversalTIOEmblems': 'HyperX Emblems',
}

def category(model):
    m = model.lower()
    for key, cat in [('headset', 'headset'), ('mousepad', 'mousePad'), ('mouse', 'mouse'),
                     ('keyboard', 'keyboard'), ('microphone', 'microphone'), ('webcam', 'webcam')]:
        if key in m:
            return cat
    return 'other'

entries = {}
for r in d['rules']:
    model = cls_model.get(r['cls'])
    if not model:
        continue
    name = manual.get(model) or titles.get(model)
    if not name:
        sys.exit(f'sem nome para {model}')
    if not name.startswith('HyperX'):
        name = 'HyperX ' + name
    for vid, pid, _ in r['ids']:
        key = (int(vid, 16), int(pid, 16))
        prev = entries.get(key)
        # Um mesmo VID/PID pode aparecer como endpoint normal e como DFU: o normal vence.
        if prev is None or (prev['dfu'] and not r['dfu']):
            entries[key] = dict(name=name, model=model, cat=category(model), dfu=r['dfu'])

lines = [
    '// GERADO por hyperx/tools/gen_catalog_swift.py a partir do NGENUITY 2.38',
    '// (HyperXCenter.AddDevice + HyperXDeviceUtils). Não editar à mão.',
    '',
    'enum DeviceCatalog {',
    '    enum Category: String {',
    '        case headset, keyboard, mouse, mousePad, microphone, webcam, other',
    '    }',
    '',
    '    struct Entry {',
    '        let vendorID: Int',
    '        let productID: Int',
    '        let name: String',
    '        /// `HyperXDeviceModel` do NGENUITY.',
    '        let model: String',
    '        let category: Category',
    '        /// Aparelho em modo de atualização de firmware.',
    '        let firmwareUpdateMode: Bool',
    '    }',
    '',
    '    static func entry(vendorID: Int, productID: Int) -> Entry? {',
    '        byID[vendorID << 16 | productID]',
    '    }',
    '',
    '    static let vendorIDs: Set<Int> = Set(entries.map(\\.vendorID))',
    '',
    '    private static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.vendorID << 16 | $0.productID, $0) })',
    '',
    '    static let entries: [Entry] = [',
]
for (vid, pid), e in sorted(entries.items(), key=lambda kv: (kv[1]['name'], kv[0])):
    lines.append(f'        Entry(vendorID: 0x{vid:04X}, productID: 0x{pid:04X}, name: "{e["name"]}", '
                 f'model: "{e["model"]}", category: .{e["cat"]}, firmwareUpdateMode: {str(e["dfu"]).lower()}),')
lines += ['    ]', '}', '']
open(sys.argv[2], 'w').write('\n'.join(lines))
print(len(entries), 'IDs,', len({e['model'] for e in entries.values()}), 'modelos')

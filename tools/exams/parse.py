# Turns the 大考中心 學測英文 papers and their official answer sheets into ios/JuanGo/exams.json:
# the multiple-choice part (詞彙, 綜合測驗, 文意選填, 篇章結構, 閱讀測驗; questions 1–46). The 混合題 and
# the written part have no single answer and are left out, as are questions whose options are pictures.
#
#   swift tools/exams/pdflines.swift tools/exams/pdf/115-paper.pdf > /tmp/115-paper.json   (and -answers)
#   python3 -I tools/exams/parse.py /tmp 113 114 115 > ios/JuanGo/exams.json
#
# 試題 are not covered by copyright (著作權法 §9 I(5): 依法令舉行之考試試題); answers are CEEC's own.
import json, re, sys

SECTIONS = [('一、詞彙', 'vocab', '詞彙題'), ('二、綜合測驗', 'cloze', '綜合測驗'), ('三、文意選填', 'fill', '文意選填'),
            ('四、篇章結構', 'structure', '篇章結構'), ('五', 'reading', '閱讀測驗')]
LETTERS = 'ABCDEFGHIJ'


def answers(lines):
    rows = {}
    for l in lines:
        rows.setdefault(round(l['y']), []).append(l)
    out = {}
    for y in sorted(rows):
        toks = ' '.join(l['t'] for l in sorted(rows[y], key=lambda l: l['x'])).split()
        i = 0
        while i < len(toks) - 1:
            if toks[i].isdigit() and re.fullmatch(r'[A-J]+|／', toks[i + 1]):
                out[int(toks[i])] = toks[i + 1]; i += 2
            else:
                i += 1
    return out


def body(lines):
    """The paper's lines in reading order, without page furniture and picture labels."""
    keep = []
    for l in lines:
        t = l['t'] = re.sub(r'\(\s*([A-J])\s*\)', r'(\1)', l['t'])   # "( I )" is (I)
        if l['p'] == 1 or l['y'] < 70 or l['y'] > 780 or '請記得' in t or '￼' in t:
            continue
        # labels inside a map or chart (a 篇章 line that opens with its blank box sits further in)
        if l['x'] > 95 and not re.match(r'^\(?[A-J]\)|^\d{1,2}\s', t):
            continue
        keep.append(l)
    return sorted(keep, key=lambda l: (l['p'], l['y'], l['x']))


def join(parts):
    s = ''
    for p in parts:
        s = s + p if s.endswith('-') or not s else s + ' ' + p
    return re.sub(r'\s+', ' ', s).strip()


def split_options(text):
    bits = re.split(r'\(([A-J])\)\s*', text)
    return [b.strip() for b in bits[2::2]]


def parse(year, d):
    paper = body(json.load(open(f'{d}/{year}-paper.json')))
    key = answers(json.load(open(f'{d}/{year}-answers.json')))
    groups, section, group, para, cur = [], None, None, [], None   # cur: the question being read

    def close_para():
        nonlocal para
        if para and group is not None:
            group['paras'].append(join(para))
        para = []

    def new_group():
        nonlocal group
        close_para()
        group = {'section': section[2], 'kind': section[1], 'paras': [], 'shared': [], 'questions': [], 'range': None}
        groups.append(group)

    for l in paper:
        t = l['t']
        if t.startswith('第貳部分'):
            close_para(); break
        hit = next((s for s in SECTIONS if re.sub(r'\s', '', t).startswith(s[0]) and '占' in t), None)
        if hit:
            close_para(); section = hit; group = None; cur = None
            if hit[1] == 'vocab':
                new_group()
            continue
        if section is None or t.startswith('說明'):
            continue
        m = re.match(r'^第\s*(\d+)\s*至\s*(\d+)\s*題為題組', t)
        if m:
            new_group(); cur = None
            group['range'] = (int(m.group(1)), int(m.group(2)))
            continue
        m = re.match(r'^(\d{1,2})\.\s*(.*)', t)
        if m and l['x'] < 70:
            close_para()
            cur = {'n': int(m.group(1)), 'text': [m.group(2)]}
            group['questions'].append(cur)
            continue
        if cur is None and section[1] in ('fill', 'structure') and (re.match(r'^\([A-J]\)', t) or group['shared']):
            close_para(); group['shared'].append(t); continue
        if cur is not None:
            cur['text'].append(t); continue
        # passage text: an indented line starts a paragraph
        if l['x'] > 80 and para:
            close_para()
        para.append(t)
    close_para()

    out = []
    for g in groups:
        shared = split_options(join(g['shared'])) if g['shared'] else []
        if shared and not g['questions'] and g['range']:
            # 文意選填 and 篇章結構: the questions are the blanks themselves
            g['questions'] = [{'n': n, 'text': []} for n in range(g['range'][0], g['range'][1] + 1)]
        qs = []
        for q in g['questions']:
            text = join(q['text'])
            first = re.search(r'\([A-J]\)', text)
            stem, opts = (text[:first.start()].strip(), split_options(text[first.start():])) if first else (text, [])
            a = key.get(q['n'], '／')
            if a == '／' or len(a) != 1:
                continue
            if not shared and (len(opts) < 4 or any(not o for o in opts)):
                continue                                   # picture options
            qs.append({'n': q['n'], 'stem': stem, 'options': opts, 'answer': LETTERS.index(a)})
        if not qs:
            continue
        passage = '\n\n'.join(g['paras'])
        if g['kind'] in ('cloze', 'fill', 'structure'):
            # the numbered blanks, in order, become ⟨n⟩ for the app to draw
            pos = 0
            for q in qs:
                m = re.compile(r'(?:(?<=\s)|^)' + str(q['n']) + r'(?=[\s,.;:!?’”—])', re.M).search(passage, pos)
                if m:
                    passage = passage[:m.start()] + f'⟨{q["n"]}⟩' + passage[m.end():]
                    pos = m.start()
                else:
                    print(f'{year}: blank {q["n"]} not found', file=sys.stderr)
        out.append({'section': g['section'], 'kind': g['kind'], 'passage': passage or None,
                    'shared': shared or None, 'questions': qs})
    return {'year': int(year), 'title': f'{year} 學年度學測英文', 'groups': out}


d = sys.argv[1]
exams = [parse(y, d) for y in sys.argv[2:]]
for e in exams:
    n = sum(len(g['questions']) for g in e['groups'])
    print(e['year'], n, 'questions', file=sys.stderr)
json.dump(sorted(exams, key=lambda e: -e['year']), sys.stdout, ensure_ascii=False, separators=(',', ':'))

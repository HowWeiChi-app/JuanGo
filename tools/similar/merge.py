# Writes the similar words from sim.swift into words.json as "sim" (3 at most per word).
#   swift tools/similar/sim.swift ios/JuanGo/words.json > /tmp/sim.json && python3 tools/similar/merge.py ios/JuanGo/words.json /tmp/sim.json
import json, sys
words_path, sim_path = sys.argv[1], sys.argv[2]
words = json.load(open(words_path, encoding='utf-8'))
sim = json.load(open(sim_path, encoding='utf-8'))
n = 0
for e in words:
    s = sim.get(e['w'].lower())
    if s and e.get('zh'):
        e['sim'] = s[:3]; n += 1
    else:
        e.pop('sim', None)
json.dump(words, open(words_path, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
print(n, 'entries with similar words')

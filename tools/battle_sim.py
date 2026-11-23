#!/usr/bin/env python3
"""Simulates ranked battles with supabase/battle_rules.json to check the targets in the plan.

    python3 tools/battle_sim.py

Opponents play like the computer of their tier (its accuracy and answer times); half the games are against
the computer (base points 3 smaller), half against a player of about the same rating.
Also checks that the rules embedded in supabase/battle_ranked.sql match the JSON file.
"""
import json
import math
import random
import re
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
R = json.loads((ROOT / "supabase/battle_rules.json").read_text())


def tier(r):
    ts = R["tiers"]
    i = max(k for k, t in enumerate(ts) if r >= t["from"])
    t = dict(ts[i], index=i + 1)
    if i == len(ts) - 1:
        top = R["above_top"]
        steps = max(0, (r - t["from"]) // top["every"])
        t["bot"] = min(top["bot_max"], t["bot"] + steps * top["bot_step"])
        t["win"] = max(top["win_min"], t["win"] + steps * top["win_step"])
    return t


def points(ms, right):
    if not right:
        return 0
    p = R["points"]
    speed = 0 if ms < p["min_ms"] else p["speed"] * (1 - min(ms, R["round_ms"]) / R["round_ms"])
    return round(p["correct"] + speed)


def play(acc, ms_mean, opp_acc, opp_ms):
    """One game of 10 questions; returns (my score, my correct, my avg ms, opp score, opp correct)."""
    n = R["rounds"]
    s1 = c1 = s2 = c2 = 0
    total_ms = 0
    for _ in range(n):
        r1 = random.random() < acc
        m1 = max(600, min(9800, random.gauss(ms_mean, 1000)))
        r2 = random.random() < opp_acc
        m2 = max(600, min(9800, random.gauss(opp_ms, 1100)))
        s1 += points(m1, r1); c1 += r1; total_ms += m1
        s2 += points(m2, r2); c2 += r2
    return s1, c1, total_ms / n, s2, c2


def clamp(x, lo, hi):
    return max(lo, min(hi, x))


class Player:
    def __init__(self, level, acc, ms):
        self.rating = R["start_rating"][level - 1]
        self.level = level
        self.acc, self.ms = acc, ms
        self.games = self.wins = 0
        self.streak = 0
        self.rookie_games = 0
        self.rookie_bonus = 0
        self.rookie_done = self.rating >= R["rookie"]["until"]
        self.bot_streak = 0
        self.bot_recent = []

    def bot_accuracy(self):
        t = tier(self.rating)
        if not self.rookie_done and self.level <= 3:
            ro = R["rookie"]
            return min(ro["bot_max"], R["tiers"][self.level - 1]["bot"] + ro["bot_bonus"])
        b = R["bot"]
        if abs(self.bot_streak) >= b["streak"] and len(self.bot_recent) >= b["streak"]:
            a = statistics.mean(self.bot_recent[-b["streak"]:])
            return clamp(clamp(a, t["bot"] - b["adjust"], t["bot"] + b["adjust"]), b["min"], b["max"])
        return t["bot"]

    def game(self, vs_bot):
        t = tier(self.rating)
        b = R["bot"]
        if vs_bot:
            opp_acc = self.bot_accuracy()
            opp_rating = self.rating + random.randint(-b["rating_spread"], b["rating_spread"])
        else:
            opp_rating = self.rating + random.randint(-60, 60)
            opp_acc = tier(opp_rating)["bot"]
        lo, hi = b["speed_ms"][min(tier(opp_rating)["index"], len(b["speed_ms"])) - 1]
        opp_ms = (lo + hi) / 2
        s1, c1, ms, s2, c2 = play(self.acc, self.ms, opp_acc, opp_ms)
        outcome = "win" if (s1, c1) > (s2, c2) else "loss" if (s1, c1) < (s2, c2) else "draw"
        self.games += 1
        if outcome == "draw":
            return 0
        win = outcome == "win"
        base = t["win"] if win else -t["loss"]
        if vs_bot:
            base += -b["base_penalty"] if win else b["base_penalty"]
        o = R["opponent"]
        opp = 0 if vs_bot else clamp(int((opp_rating - self.rating) / o["per"]), -o["max"], o["max"])
        pf = R["performance"]
        perf = clamp(round((c1 - t["bot"] * 10) * pf["per_correct"] + (4500 - ms) / 1000 * pf["per_second"]), -pf["max"], pf["max"])
        d = base + opp + perf
        if not win and c1 >= pf["brave_loss_correct"]:
            d = round(d / 2)
        if win and c1 <= pf["weak_win_correct"]:
            d = round(d / 2)
        if win:
            self.streak += 1
            st = R["streak"]
            if self.streak >= st["from"]:
                d += min(st["max"], st["first"] + (self.streak - st["from"]) * st["step"])
        else:
            self.streak = 0
        ro = R["rookie"]
        if not self.rookie_done:
            if d > 0:
                extra = min(round(d * (ro["factor"] - 1)), ro["cap"] - self.rookie_bonus)
                d += extra
                self.rookie_bonus += extra
            self.rookie_games += 1
        d = max(d, R["floor"]["win"]) if win else min(d, -R["floor"]["loss"])
        self.rating = max(R["min_rating"], self.rating + d)
        if not self.rookie_done and (self.rookie_games >= ro["games"] or self.rookie_bonus >= ro["cap"] or self.rating >= ro["until"]):
            self.rookie_done = True
        if vs_bot:
            if (self.bot_streak > 0) != win:
                self.bot_streak, self.bot_recent = 0, []
            self.bot_streak += 1 if win else -1
            self.bot_recent = (self.bot_recent + [c1 / 10])[-3:]
        self.wins += win
        return d


def run(level, acc, ms, games):
    p = Player(level, acc, ms)
    for _ in range(games):
        p.game(random.random() < 0.5)
    return p


def check_sql():
    sql = (ROOT / "supabase/battle_ranked.sql").read_text()
    m = re.search(r"\$rules\$(.*?)\$rules\$", sql, re.S)
    assert m and json.loads(m.group(1)) == R, "battle_ranked.sql 裡的規則和 battle_rules.json 不一樣"


def main():
    random.seed(7)
    if (ROOT / "supabase/battle_ranked.sql").exists():
        check_sql()
        print("battle_ranked.sql 的規則和 JSON 一致")

    finals = [run(3, 0.75, 4500, 300).rating for _ in range(300)]
    print(f"答對 75%：300 場後平均 {statistics.mean(finals):.0f}（中位數 {statistics.median(finals):.0f}）")

    finals = [run(6, 0.95, 2500, 600).rating for _ in range(200)]
    print(f"答對 95%、很快：600 場後平均 {statistics.mean(finals):.0f}，最低 {min(finals)}")

    pop = []
    for _ in range(2000):
        acc = clamp(random.gauss(0.72, 0.1), 0.4, 0.99)
        ms = clamp(random.gauss(4500, 1000), 1500, 8000)
        level = clamp(round((acc - 0.55) / 0.06), 1, 6)
        pop.append(run(level, acc, ms, 300).rating)
    top = sum(r >= 2500 for r in pop) / len(pop)
    print(f"2000 人各打 300 場：2500 以上 {top:.2%}，2000 以上 {sum(r >= 2000 for r in pop) / len(pop):.2%}")

    # 50% win rate from 1000: the accuracy that wins about half the time against 1000-1100 opponents
    best = None
    for acc in [x / 100 for x in range(60, 80)]:
        rs = [run(2, acc, 4500, 50) for _ in range(300)]
        wr = statistics.mean(p.wins / p.games for p in rs)
        if best is None or abs(wr - 0.5) < abs(best[1] - 0.5):
            best = (acc, wr, rs)
    acc, wr, rs = best
    finals = [p.rating for p in rs]
    bonus = [p.rookie_bonus for p in rs]
    print(f"1000 起始、勝率 {wr:.0%}（答對 {acc:.0%}）：50 場後平均 {statistics.mean(finals):.0f}，"
          f"超過 1400 的 {sum(f > 1400 for f in finals) / len(finals):.1%}，新手加成平均 {statistics.mean(bonus):.0f}、最多 {max(bonus)}")


if __name__ == "__main__":
    main()

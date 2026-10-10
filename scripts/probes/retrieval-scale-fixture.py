#!/usr/bin/env python3
"""Generate a bounded synthetic capacity corpus, not a natural-history acceptance set."""
import argparse
import hashlib
import json
from pathlib import Path

TOPICS = [
    "自行车轮胎气压要按轮胎规格检查，补胎前先找漏气位置。",
    "厨房锅具清洗后擦干，番茄切块准备晚饭，不要把盐当糖。",
    "阳台植物换盆先检查排水，过湿的介质容易积水。",
    "衣服纽扣松了，可以选同色线缝牢，袖长要按实际尺寸修改。",
    "陶艺作品入窑前晾干，釉色和烧制温度分别记录。",
    "水彩画调色先试小样，纸张吸水速度会影响边缘效果。",
    "火车座位分布要查看实际车次，靠窗位置不是每节车厢都相同。",
    "公园散步路线尽量避开积水，出门前看降雨情况。",
    "床垫记忆棉慢慢回弹，选择时对比材料密度和软硬程度。",
    "无线耳机连接失败时检查蓝牙配对与剩余电量。",
    "家具的宽度与门口净宽分别测量，搬运前留出转角空间。",
    "咖啡研磨粗细改变萃取速度，不同豆子分别记下水温。",
    "饼干烤制时使用同一盘位置，观察边缘颜色防止烤焦。",
    "天文望远镜对焦时慢慢调整，光轴偏移会影响成像。",
    "弦乐器定音先参考基准音，换弦后重新检查张力。",
    "海边出行带防水袋，潮汐时间要看当地公告。",
    "棋盘上的骑士走日字，车沿横线和竖线移动。",
    "汽车轮胎磨损与胎压分别检查，记录里程便于维护。",
    "电池充电线接口要匹配，电量不足时先确认电源插座。",
    "纸质地图标出山路岔口，徒步背包的水和食物分开放。",
    "整理每月房租餐费的现金流，收支金额分别归档。",
    "数学分数通分后比较大小，分母不同不能直接比较分子。",
    "小说里的城堡资源属于虚构设定，人物台词与叙述者分开。",
    "羽毛球拍穿线张力要按球拍规格，断线后先检查拍框。",
    "花瓶与桌布的颜色先摆在一起观察，再决定布置位置。",
    "露营帐篷在平地搭好，风绳固定后检查地钉。",
    "橄榄油瓶盖拧紧放阴凉处，选购时看等级与产地。",
    "剪纸时先画轮廓，折叠边缘需要留出连接位置。",
    "手工皂用模具定型，脱模后分别记录批次和配色。",
    "台灯亮度太高可以调低，书桌左右位置影响阴影。",
    "玻璃杯用温水清洗，裂纹杯子不能继续受热。",
    "烘干衣物时把厚毛巾和薄衬衫分开，观察标签建议。",
]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("base_fixture", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--count", type=int, choices=[100, 1000], required=True)
    a = p.parse_args()
    raw = a.base_fixture.read_bytes()
    base = json.loads(raw)
    if base.get("synthetic") is not True:
        p.error("Synthetic base required")
    originals = {d["id"]: d for d in base["documents"]}
    slots = {a.count // 4: "device_transfer", a.count // 2: "sensor_limit", a.count - 1: "review_schedule"}
    documents = []
    for i in range(a.count):
        if i in slots:
            documents.append(originals[slots[i]])
        else:
            documents.append(dict(id=f"distractor-{i:04d}", text=f"第{i + 1}份生活记录：" + TOPICS[i % len(TOPICS)] + f"记录序号{i + 1}，地点分区{i % 17 + 1}。"))
    selected = {q["id"]: q for q in base["queries"]}
    queries = [selected[qid] for qid in ["C01", "C02", "C09", "H01", "H02", "H03", "H12"]]
    fixture = dict(version="scale-v1", synthetic=True, base_sha256=hashlib.sha256(raw).hexdigest(),
                   purpose="Capacity/rank test: 32 repeated theme templates with distinct indices; not 1000 independent semantics",
                   positive_positions=slots, documents=documents, queries=queries)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(documents=len(documents), positive_positions=slots, fixture_sha256=hashlib.sha256(a.output.read_bytes()).hexdigest())))


if __name__ == "__main__":
    main()

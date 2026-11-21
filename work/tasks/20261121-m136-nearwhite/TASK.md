# 136 浅色底色抬亮：暖近白一家人

## 背景
用户：「整体底色还是太灰，不具备现代的简约高级风格」。此前路径是「灰画布 + 白卡 → 同层灰」，解决了白块突兀但整体仍偏中灰。

## 决定
整套浅色上移到暖近白，层级关系不变（同层卡片、侧栏低几级、边框分组）：
- graphite：canvas 0xF2F2F3 → 0xF6F6F4（暖白）、surface 0xF4F4F5 → 0xF9F9F7、sidebar 0xEFEFF1 → 0xEFEFEC、selection 0xE7E7E7 → 0xE9E9E5、border 0xD5D5D8 → 0xDCDCD6。
- sage：canvas 0xF5F7F0、surface 0xF8FAF4、sidebar 0xEEF1E7、selection 0xE7ECDD、border 0xD8DFCE。
- 深色四值不动。

## 实测
surface/canvas 1.03、sidebar/canvas 1.06、border 1.31、selection 1.15；正文 15.5:1（graphite）/ 12.3:1（sage）。

## 风险
若「近白」仍显平淡，下一步是加极轻的表面阴影/描边对比或引入纸感暖调，而不是继续抬亮。

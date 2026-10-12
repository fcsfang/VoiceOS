# ADR029 稳定开发签名身份

日期：2026-10-12。状态：本机开发构建采用，系统权限恢复待验证。路线：W01/W04/W23。

问题：用户确认此前已授权；原生系统设置也显示VoiceOS提醒事项开关on，但应用返回权限不可用。现构建脚本固定 codesign --sign -，当前 designated requirement 仅为 cdhash；程序更新后权限身份随之变化。不能把系统开关on等同当前进程通过授权，也不能把签名通过等同权限已修复。

选择：使用系统中既有且有效的唯一Apple Development身份签署本机开发构建；多个或没有候选时要求明确 --signing-identity，不静默降级。保留显式 --adhoc 供不依赖持续隐私授权的临时构建。不会创建证书、导出私钥、修改TCC数据库、清空已有授权或改变清单范围。

备选：继续临时签名，构建简单但权限连续性差；仅标识符的自定义临时签名要求不能等同证书身份；新建自签证书需要额外密钥管理；Developer ID分发证书及公证属于未来安装分发范围。已有Apple Development证书可解决开发身份稳定性，尚不能代替正式分发方案。

证据：security find-identity检测到一个有效候选；签署和严格验证成功。新DR包含 local.voiceos.app标识、Apple证书锚和签名证书，而非单一代码hash。用户设置开关on已通过CUA只读确认；旧进程曾显示测试清单成功回读，稳定签名重启后仍显示权限不可用，具体TCC绑定原因尚未证明。权限日志和只读TCC诊断未给出可用记录；不得宣称根因完全确认或权限恢复。

[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)说明DR用于隐私资源的代码身份，临时签名DR绑定特定代码版本，开发与分发DR默认也可能不同。下一步验证一次系统授权与稳定身份绑定后的重启/更新连续性，保留既有外部任务和清单授权。

# Proxy Hotspot

把 Windows 热点网络一键接入 Clash。自动识别网卡、启动热点和恢复设置。

## 使用

以管理员身份打开 Mihomo 客户端，选好节点。在 Windows 设置中配置热点名称和密码。

```bat
hotspot.cmd start
hotspot.cmd status
hotspot.cmd collect
hotspot.cmd stop
```

双击 `hotspot.cmd` 等同于 `start`。启动、停止和采集会请求管理员权限。

支持控制接口的 Mihomo 内核会自动开启 TUN；其他客户端先手动开启虚拟网卡。

多网卡时指定名称：

```bat
hotspot.cmd start -Wifi "WLAN" -Tun "Mihomo" -Internet "以太网"
```

重启共享服务后启动：

```bat
hotspot.cmd start -Repair
```

恢复启动前的热点开关状态：

```bat
hotspot.cmd restore
```

## 输出

| 文件 | 内容 |
| --- | --- |
| `data/reports/*.txt` | 网卡、路由、热点、共享和内核状态 |
| `data/session.json` | 本次会话与原设置 |
| `data/result.json` | 最近一次命令结果 |
| `data/hotspot.log` | 操作日志 |


## 工作方式

使用 Windows 原生热点接口，将 Mihomo 连接配置设为上游，识别实际热点下游并重新绑定。保留现有热点名称、密码、DNS 和代理规则。

启动时关闭物理出口的 IPv4 转发。停止时恢复原值，并关闭由脚本开启的 TUN。采用当前运行状态，不写入永久网卡配置。

`status` 显示共享角色和热点设备的代理连接计数。手机连接后打开 Google，再运行一次 `status` 查看结果。

## 测试

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

环境：Windows 10/11、Windows PowerShell 5.1、Mihomo。

## 打包

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package.ps1
```

生成 `dist/proxy-hotspot.zip`。

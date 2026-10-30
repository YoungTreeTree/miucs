# 插件运行时与验证

Miucs 只使用 Lua 5.4/Skia 可视化。内置四个独立插件：

| 菜单名称 | 稳定 ID | 默认顺序 |
| --- | --- | --- |
| 奶牛猫 | `pixel-keyboard` | 1，首次启动默认 |
| 麦芬 | `muffin-puppies` | 2 |
| 牛来 | `niulai-keyboard` | 3 |
| 平次与和叶 | `heiji-kazuha` | 4 |

重命名保留插件 ID，因此奶牛猫已有的选择、位置和尺寸继续有效。失效的保存选择回退到奶牛猫；有效的其他选择继续保留。用户安装的自定义插件排在内置插件之后。

每个插件在隔离 worker 中运行 Lua；宿主将音频和键盘快照打包传输，Skia 在宿主绘制。macOS 使用 Metal，Windows 使用 D3D12/DirectComposition，初始化失败时回退到 CPU。应用猫图标、窗口、输入采集与恢复独立于插件。

Lua 内存、场景、图像、控制队列和脚本执行时间均有限额。输入更新合并到最新快照，短事件保留有界队列；无变化补丁跳过场景复制。切换释放旧 worker 和 surface；热重载先验证候选，再替换当前 worker。Metal drawable 使用作用域释放，CPU surface 销毁时移除子图层并清空最后一帧图像。

```sh
sh scripts/build-plugins.sh
sh scripts/test-plugins.sh
zsh scripts/test-plugin-macos.sh
python3 tools/plugins/fixture.py
build/plugins/plugin-surface-probe build/plugins/miucs-plugin-worker plugins/pixel-keyboard build/plugin-fixture.json
MIUCS_FORCE_CPU=1 build/plugins/plugin-surface-probe build/plugins/miucs-plugin-worker plugins/pixel-keyboard build/plugin-fixture.json
build/plugins/plugin-benchmark plugins build/plugin-fixture.json
python3 tests/plugins/soak.py --seconds 1800
```

macOS 与 Windows 共享插件场景和输入契约。离屏绘制、合成回放和 CI 不能替代真实采集、权限、混合 DPI、GPU 和长期内存验证；Windows 状态见[实机验收表](windows-acceptance.md)。

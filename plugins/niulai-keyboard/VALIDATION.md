# 验证记录
2026-10-29，dot Linux云端，系统liblua5.4。
- tests/run_lua54.py通过：motion/lifecycle 1,419,634字段断言；下方keyboard18,759检查。断言数不是独立测试案例数。
- 上方：600帧无触发不循环、音乐独立换刃穿过中间姿态、键盘独立触发完整12帧跳跃、+1ms源时钟偏移、重复beat去重、长gap不补播、生命周期幂等、节点字段有限数。
- 下方：多键高亮与释放留在最后击键位置、物理hold/release、新订阅hold不伪造strike、左右modifier、caps、space轮换、repeat/unknown忽略、session/stale/secureInput/长gap、+1ms偏移。
- 实际Lua场景导出200帧，离线Pillow渲染8秒合成输入预览；H264/yuv420p MP4200帧8秒，非Skia原生截图或真实音频捕获。
- 图集2张880x660 RGBA，共约4.65MB未压缩像素；固定节点，不逐帧创建。
- 尚未验证：Miucs原生Skia热加载、macOS/Windows实机、系统输入权限。此记录仅说明云端测试范围。此前0.1.0在独立原生worker+Skia合成验证通过；真实输入GUI与热加载体验未完成验收。
- 美术：24帧来自已有AI牛来像素素材，部分相邻姿态差异仍大，未声称完成更细腻逐帧重绘。

0.1.1：最低宽度480修正为80，设计画布800×460与最大宽1600保持不变；schema和上述两套Lua测试重新通过。未更改宿主或用户偏好。

仓库集成验证：Linux云端使用项目校验的Lua5.4.8/JSON依赖直接编译未修改的生产worker，tests/plugins/niulai_replay.py通过138条断言，10秒低/高打字速度分别4/10次跳跃。包含无输入不循环、beat换刃、+1ms源时钟偏移、音频缺失时独立打字、多键释放留位、secureInput、停用及退出。此结果覆盖生产Lua/场景序列化，不包含Skia图像解码或原生窗口；Mac/Windows CI另运行生命周期、CPU渲染及surface测试。

释放行为修复：与pixel-keyboard一致，新strike才改蹄目标；松键仅原位抬起，running空闲不回F/J、也不跳到更早按住的同侧键。非running/新session仍复位。新增单侧释放、同时held、重复事件及另一侧独立回归。

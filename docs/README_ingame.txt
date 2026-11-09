StylishRank —— 《影之刃零》DMC5 风格战斗评级
================================================

右上角显示恶魔猎人风格的战斗评级徽章（D → C → B → A → S → SS → SSS），
打击、弹反、处决加分，被打掉分，站着不动会缓降，暂停/菜单时自动隐藏。
徽章会跟着背景音乐的重低音节奏放大、闪光；升阶时播放对应音效。

整个 mod 由两部分组成：

  StylishRank  —— 评级徽章 + 计分（PBZModLoader / JS）
  StylishAudio —— 音效 + 音乐律动（UE4SS / Lua + 常驻 PowerShell 服务）

只有评分逻辑一套，在 StylishRank 里；StylishAudio 只负责播声音和让徽章跟着音乐动。


================
一、需要先装好
================

  * PBZModLoader 0.3.6-preview 或更新（Nexus mod 113，作者 LLKKFF）
  * UE4SS 3.0.1 + 对应本游戏版本的签名修复（Signature Patch）
    只需要音效/音乐律动时才需要；只用徽章可以跳过。
  * 游戏目录有写入权限（不要装在 Program Files 且权限受限的位置）


================
二、安装
================

1. 完全退出游戏。

2. 把 StylishRank 文件夹放到：

     <游戏目录>\ProjectPBZ\PBZModLoader\mods\StylishRank\

   最终应是：
     ...\mods\StylishRank\main.js
     ...\mods\StylishRank\rankImages.js
     ...\mods\StylishRank\README.txt

   PBZModLoader 会自动发现新 mod，不需要改 mods.ini / mods.txt。

3. 把 StylishAudio 文件夹放到：

     <游戏目录>\platform\steam\ue4ss\Mods\StylishAudio\

   最终应是：
     ...\Mods\StylishAudio\enabled.txt
     ...\Mods\StylishAudio\Scripts\main.lua
     ...\Mods\StylishAudio\audio\rank_service.ps1
     ...\Mods\StylishAudio\audio\PeakMeter.cs
     ...\Mods\StylishAudio\audio\WavGain.cs
     ...\Mods\StylishAudio\audio\D.WAV ... SSS.WAV
     ...\Mods\StylishAudio\audio\volume.txt   （首次运行时自动生成）
     ...\Mods\StylishAudio\audio\keys.txt     （默认按键，可自行修改）

   UE4SS 看到 enabled.txt 就会自动加载，不用改 mods.txt / mods.json。

4. 如果游戏里没有声音（徽章正常，只是不响）：
   这通常是 Windows PowerShell 默认禁止运行本地脚本。
   只需执行一次（普通 PowerShell 窗口，不用管理员）：

     Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

   只影响当前用户，脚本来自本机时允许运行。

5. 启动游戏。


================
三、玩法
================

  * 进战斗并打中敌人、分数攒到 10 分，右上角才出现 D 徽章。
  * 分数越高等级越高：D 10 / C 30 / B 60 / A 90 / S 120 / SS 150 / SSS 200，
    分数上限 220。
  * 评分规则：
      攻击（每个 0.25 秒）  +2   （约 8 分/秒）
      弹反/闪避成功        +10
      弹反/闪避失败        -15
      被打中（掉血）       -10
      处决                 +10  （每个处决动作一次）
      连续 2 秒完全没动作  每秒 -20（处决/连携/格挡/闪避/受击都不算站桩）
  * 脱战后分数清零，徽章消失；暂停或打开地图/菜单时隐藏并冻结计分。
  * 升阶播一次音效，降阶不播；D 每场战斗只播一次。
  * 徽章随系统默认输出设备的音乐重低音缩放 + 泛白闪光。
  * 游戏内调升阶音量：默认按 [ 减小 / ] 增大（每次 5%），屏幕中间弹出
    音量面板，亮起的格子就是当前音量，5 秒不操作自动关闭。
    改过的音量会保存，下次开游戏还是它。
    按键冲突时改 audio\keys.txt 换键（见第四节）。


================
四、调参数（编辑 main.js）
================

  升阶音效音量：
    游戏内按 [ / ] 调整（推荐），会自动写进
    ...\StylishAudio\audio\volume.txt。
    也可以直接打开这个文件改数字，填 0~200，默认 100。
    100 = 标准音量（各等级文件已统一响度，D/C/B 不再偏小），
    200 = 两倍（可能会破音），0 = 静音。
    保存后下一次升阶立即生效，不用重启游戏、也不用重启服务。
    面板上 20 个格子，每格代表 10%。

  音量面板按键：...\StylishAudio\audio\keys.txt（默认按键，可自行修改）
    按一下 [ 或 ] 就会弹出面板调音量，5 秒不操作自动收起。
    等号右边换成你想要的键即可，保存后约 2 秒自动生效，不用重启。
      down = [     减小音量
      up   = ]     增大音量
    支持的键名：A-Z、0-9、F1-F12、[ ] / \ ; ' , . - = `，
    以及 SPACE TAB ENTER ESC HOME END INS DEL UP_ARROW DOWN_ARROW 等。
    如果某个键和游戏或其他 mod 冲突，换成别的就行。

  RANK_MIN         各等级门槛，默认 [10, 30, 60, 90, 120, 150, 200]
  SCORE_MAX        分数上限，默认 220（必须大于 SSS 门槛）
  SCORE_MELEE      每次攻击判定加分，默认 2
  SCORE_DEFLECT    弹反/闪避成功加分，默认 10
  SCORE_DEFLECT_FAIL 弹反/闪避失败扣分，默认 15
  SCORE_DAMAGE     受击扣分，默认 10
  SCORE_EXECUTION  处决加分，默认 10
  IDLE_GRACE_MS    多久没动作开始掉分，默认 2000 毫秒
  SCORE_IDLE_DRAIN 站桩每秒扣分，默认 20
  MARGIN           徽章距屏幕边缘的距离，默认 44
  SLOT_W / SLOT_H  徽章槽位尺寸，默认 200 x 200

  改完保存，游戏里按 Alt+F5 热重载，不用重启。

  音效音量/节拍灵敏度在
  ...\StylishAudio\audio\rank_service.ps1 里（onset 阈值和 gain）。
  改 ps1 需要关游戏重开（服务是常驻进程）。


================
五、常见问题
================

  徽章不出现
    看 <游戏目录>\ProjectPBZ\PBZModLoader\evidence\<最新时间>\loader.log，
    搜索 "[StylishRank]"。

  没有升阶音效
    看 <游戏目录>\platform\steam\ue4ss\UE4SS.log，搜索 "[StylishAudio]"。
    正常会看到 "service alive after attempt 1"。
    如果一直 "service not alive"，按上面第 4 步设置 PowerShell 执行策略。
    也可以看 audio\alive.txt 的时间戳是否在每秒更新。

  徽章不跟音乐动
    说明音量采样没起来。删除 audio\meter_error.txt 后再进游戏，
    如果它又出现，把里面的报错发到反馈贴。
    另外：音乐要真的从「系统默认输出设备」播放；
    如果游戏走的是其他输出设备（某些虚拟声卡 / 分开的 HDMI），可能采不到。

  改了 Lua 没效果
    UE4SS 不热重载 Lua，必须重启游戏。JS（main.js）可以 Alt+F5。


================
六、卸载
================

  删除
    <游戏目录>\ProjectPBZ\PBZModLoader\mods\StylishRank\
    <游戏目录>\platform\steam\ue4ss\Mods\StylishAudio\

  不会改动任何游戏原始文件。


================
Quick Install (English)
================

  1. Install PBZModLoader 0.3.6-preview+ (Nexus mod 113) and, for sound,
     UE4SS 3.0.1 + the matching signature patch.
  2. Copy "StylishRank" to <game>\ProjectPBZ\PBZModLoader\mods\StylishRank\
  3. Copy "StylishAudio" to <game>\platform\steam\ue4ss\Mods\StylishAudio\
  4. If rank-up sounds stay silent, run once:
       Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
  5. Start the game. Hot reload JS with Alt+F5; Lua changes need a restart.

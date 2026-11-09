## 成绩上传结束（成功 / 未写入）后是否需要重新拉取数据的门控。
##
## 背景：中途退出 PlayView 时成绩上传是 fire-and-forget，回到 MidiView 时它往往还在路上。
## 若「回页刷新」和「上传完成刷新」各刷一次，排行榜/评论会被 clear_items 连清两遍
##（闪一下 + 滚动位置弹回顶部），并多打一轮 leaderboard / stats / comments 请求。
## 现在的约定：
##   ① 回页时若该谱面仍在上传，推迟刷新（MidiView._on_state_changed）；
##   ② 上传结束时按本门控判断是否刷新——只在「本页正是当前视图」时刷。
## 两条合起来保证一次打歌只刷一次。
##
## 抽成纯函数而不是写在视图里，是为了能在 headless 场景测试中直接断言
##（两个消费方 ScoreList / CommentArea 都依赖大量兄弟节点，不好单独实例化）。
##
## 消费方一律 `const UploadRefreshGate := preload(...)` 后调用，不依赖 class_name 缓存。
extends RefCounted


## current_hash 是本视图当前绑定的谱面（未加载过时为空）；
## uploaded_hash 是本次上传结束事件携带的谱面；
## state 是 UiStatMGR.current_state；online 是调用方自己的在线判定结果。
## 不在 MIDI_VIEW 时不刷：下次进入 MIDI_VIEW 的回页刷新会拿到最新数据。
static func should_refresh(current_hash: String, uploaded_hash: String,
		state: int, online: bool) -> bool:
	if current_hash.is_empty() or current_hash != uploaded_hash:
		return false
	if state != UIStateManager.UIState.MIDI_VIEW:
		return false
	return online

# 可选：提交给上游的文字草稿

> 说明：你没让我提，这份只是备着。哪天想提交了直接复制。
> 注意 GitHub 的 issue 正文**不支持**用链接预填，所以只能手动粘贴。
> 目标页：https://github.com/robbietilton/Compositor/issues/70

---

## 贴到 #70 的评论（英文，上游用英文）

```
Adding data to this, and one factual correction to the reasoning in #9.

I measured the shipped v1.2.4 binary rather than reading the README. Of its 1738 imported
symbols, 18 are missing on macOS 15.8 — 17 SwiftUI symbols plus `swift_coroFrameAlloc`.
That is 99.0% already compatible. The SwiftUI ones are:

  - ToolbarSpacer / SpacerSizing            (used at ContentView.swift:160, :173)
  - ToolbarContent.sharedBackgroundVisibility(:)  (ContentView.swift:169)
  - _TaskValueModifier2, _TagTraitWritingModifier, ForEach.create(_:content:)

The last three come from `.task(id:)`, `.tag()` and `ForEach`, and disappear on their own
if the deployment target is lowered — they are just the newer internal implementations the
compiler picks when the target allows it. So the actual source changes needed are the five
call sites in ContentView.swift, which is what #8 had already done.

The correction: #9 says "every Mac that can run 15 can run 26". That isn't true. macOS 26
supports only four Intel Macs — the 2019 16" MacBook Pro, the 2020 13" MBP with four
Thunderbolt ports, the 2020 iMac, and the 2019 Mac Pro. A 2019 iMac (iMac19,1), a 2019
MacBook Air, a 2018 Mac mini and a 2017 iMac Pro all run macOS 15 Sequoia today and have
no supported path to 26. For those users there is no "macOS updates are free" option.

I understand not wanting to constrain the main target. Would you consider shipping the
legacy build as a second artifact instead — same source, built from a separate
configuration with a lower deployment target? Then main stays on 26.5 and nobody has to
carry `@available` fallbacks in the primary code path.
```

---

## 如果更想开新 issue（不推荐，会被判重复）

标题：

```
Ship a separate legacy build (macOS 15 deployment target)
```

正文可以用上面评论的开头两段 + 最后一段，并把中间的更正段落放在最前面。

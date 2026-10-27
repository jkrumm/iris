# Vendored skills

Copied verbatim from upstream, one directory per skill, each with its upstream `LICENSE` (MIT, © 2026 Paul Hudson).
Do not edit the copies. Iris-specific guidance goes in `.claude/rules/swift.md` or an own skill.

| Skill | Upstream | Pinned commit | Commit date |
|-|-|-|-|
| `swiftui-pro` | `twostraws/SwiftUI-Agent-Skill` (2.0.0) | `f2920b63995263f57b3e198674e89a602efba6d2` | 2026-10-26 |
| `swift-concurrency-pro` | `twostraws/Swift-Concurrency-Agent-Skill` | `bee3f69ba17142da148d3c5406f148ed62592b69` | 2026-05-17 |
| `swift-testing-pro` | `twostraws/Swift-Testing-Agent-Skill` | `2d6bba14a3c8bf3694f218b92fffe617c41ae43e` | 2026-05-17 |
| `swiftdata-pro` | `twostraws/SwiftData-Agent-Skill` | `8051f177a0076e7fd45bdf4ee687b070ba58fdc6` | 2026-10-19 |

Vendored 2026-10-27. Licence checked per repo: each root `LICENSE` is the MIT text and each `SKILL.md` declares `license: MIT`.
`swiftdata-pro` is vendored for later (history cache); nothing in the Iris plan uses SwiftData yet.

## Update procedure

```bash
d=$(mktemp -d) && cd "$d"
git clone --depth 1 https://github.com/twostraws/<Upstream-Repo>      # repo from the table
git -C <Upstream-Repo> rev-parse HEAD                                 # new pin
git -C <Upstream-Repo> diff <old-pin>..HEAD -- <skill>/               # read the diff first (skills steer the agent)
rm -rf <iris>/.claude/skills/<skill> && cp -R <Upstream-Repo>/<skill> <iris>/.claude/skills/
cp <Upstream-Repo>/LICENSE <iris>/.claude/skills/<skill>/LICENSE      # confirm it is still MIT
```

Then update the pin and date above and commit as `chore: bump vendored <skill>`. Read the diff for instructions that
contradict `.claude/rules/swift.md` or the repo's AGENTS.md before accepting it. Directory of further candidates:
`twostraws/Swift-Agent-Skills` (links only, nothing to vendor from it).

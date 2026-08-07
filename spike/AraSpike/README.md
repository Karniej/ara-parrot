# AraSpike — the Phase 0 experiments

One throwaway app + keyboard that answers the three questions gating the iOS
product (docs/IOS-BUILD-PLAN.md). Needs a physical device; experiment 1 needs
Apple Intelligence hardware (A17 Pro+).

    open AraSpike.xcodeproj   # select your iPhone, Run

1. Settings → General → Keyboard → Add New Keyboard → AraSpike → Allow Full Access
2. Open Notes, globe-switch to AraSpike, tap **1 FM**, **2 Mic**, **3 ASR**, then
   **Type report** — the keyboard types its findings into the note.
3. Turn Full Access **off**, repeat.
4. Open the AraSpike app and run the same three as the control group; **Copy**.
5. Run at least one pass on battery.

Paste both reports back into the planning session. The three verdict lines decide
the build order — see the decision table in IOS-BUILD-PLAN.md Phase 0.

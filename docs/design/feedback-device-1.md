# Owner feedback — first real use on the iPhone (2026-10-30)

From the owner's first take on the device (memo `82c8d008-…`, which reached the server with no audio; see Wave 17 D1b) and his notes
in chat. Binding for the waves that build it; earlier feedback stays binding where this file is silent.

Overall: "for the first draft it is actually really strong now".

1. **Copy as text.** The transcript (and a reply) must be copyable as plain text from the memo detail. Today the share/copy path yields
   something that is not text ("it's weird, it's not a file").
2. **Just transcribe.** Sometimes he only wants the transcript. A low-confidence auto route parks at needs-route instead of producing
   something useful; he wants a way to say "transcribe only" up front.
3. **Where are routes configured?** He could not find where routing (the destinations Iris can route to) is set up, in Settings or
   elsewhere. A new surface: render it for async review before building.
4. **Waterfall:** he does not like it much as is. Steps collapsible and collapsed by default (he does not want to see it all the time);
   rendering is not always clean, and there are gaps between steps.
5. **Cost:** two decimals always shows $0.00. Show a meaningful precision (or a sensible unit) so a real cost is visible.
6. **Level meter:** while speaking, the volume bars rise too little; the take screen otherwise "looks actually quite beautiful",
   including the microphone selection. (From the take itself, which arrived after the D1b fix: "the increase in the volume bars is
   not too high".)
7. **Accessibility text sizes are not a target (owner, 2026-10-30).** Iris is a tool for technical people steering their agents, not a
   general-audience app; nobody will run it at the largest Dynamic Type sizes. The device check for accessibility sizes is dropped. Do not
   spend work on layouts for the accessibility size categories; default and nearby sizes must still look right.
8. **Scrolling jumps.** On History the large "History" title and the content jump while scrolling; he believes Stats and Settings do the
   same. A real bug on every tab: scrolling must be smooth, with the native large-title collapse.
9. **Device steps in German.** His iPhone runs in German. Any instruction that names an iOS setting gives the German path
   (e.g. Einstellungen › Bedienungshilfen › Anzeige & Textgröße), English optional in brackets.
10. **Record crashed again** during the accessibility check: tapping Record closed the app, the Live Activity stayed at the top, and on
    reopening the take was gone (crash report from the phone, 2026-10-30 ~14:45).

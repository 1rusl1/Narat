# FULL C2 acceptance01 — BLOCKED by action error regression

Run tester-care-today-home-acceptance-20261120-01, candidate_baseae74, headedd3183.
Read-only whole8Swift. Real fullReview1 PASS;369Swift/build/welcome101.54,
149automation45.974, diff, MCP24.606, newPLUI+exactoperationledger39.327 PASS.
Old13careUI FAIL526.755:12passed/1failed/0skips. Sole failure is existing
 testCareRecommendationRefreshRejectionShowsFailure: rejected refresh error
“Couldn’t update the care recommendation.” disappears after passive read.
QA never ran; no accepted C2 SHA and no rootmerge/livebuild. OldFAIL retained
at runs/q-0e66b90a6dc60642f2f2fae3/summary.json.

Source confirms newly-added loadPendingAdviceRefresh success unconditionally
sets adviceRefreshFailed=false although pendingnil is not actionreceipt.
loadBasicCareState similarly clears basicCareEnableFailed. Separate passive
read failure from explicit mutation error (or equivalent) so successful read
recovers read availability but cannot erase rejected action. Date remains
failclosed on unknown/pending/read error. Existing test assertions unchanged.

Next small Guest-only Developer repair with existing rejection/basicreplay and
newPL rendered gates; then fresh FULL candidate_baseae74 with wholeold13+PL,
Swift/MCP/149automation/highReviewQA. Dedicated TodayC3/live/reminders remain.

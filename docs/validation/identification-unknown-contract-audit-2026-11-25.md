# READONLY unknown / insufficient-data source audit — 2026-11-25

Base: Root 226a1666ee4f92c1c1d26d983b0882080716e5d5. Static source/test inspection only. No tests executed, no network/native/account/auth-storage access, no repository edits. No confidence threshold introduced or inferred. Historical user text cannot identify an actual old job without its status/result/error_code.

## Exact answer

A usable but ambiguous/out-of-catalogue identification is designed as **succeeded + identification_status=unknown + plant_id=null**, retaining the original job/photo. Migration021 explicitly permits manual taxon confirmation and guest claim from that source. It is not intrinsically a failed job.

However, current source contains a concrete server/iOS quota-contract mismatch: usable unknown is **consumed on server**, while iOS accepts unknown only if **released**. This can turn a real successful unknown into the generic failure UI before the model receives its successful source. An injected model-level unknown therefore does not cover that real dead end.

## Source chain and exact gaps

1. `supabase/functions/_shared/AnthropicAdapter.ts:329–334,349–396`: identification provider vocabulary is identified / unknown / unusable. Unknown means ambiguous or outside closed catalogue; unusable means non-plant/poor photo. Both unknown and unusable normalize to wire unknown/null; an unlisted identified UUID also normalizes to unknown. Line376 charges unknown (and unlisted UUID), releases unusable. No numeric confidence threshold is used here.
2. `supabase/functions/analysis-worker/index.ts:202–214`: any returned identification object finalizes succeeded; non-billable is `!succeeded || !result.shouldConsumeQuota`. `analysis-worker/diagnosis-persistence.ts:215–219` passes that boolean unchanged to finish_diagnosis_job.
3. `supabase/migrations/202611120021_guest_photo_claim.sql:347–385`: non-null valid identification projection is succeeded; identified and unknown accepted; guest successful source gets seven-day source record. `202611090009_quota_settlement.sql:109` consumes succeeded iff not non-billable. No later finish/finalize override found changing this distinction.
4. Server production-path fixture tests `supabase/functions/_shared/tests/diagnosis_photo_test.ts:725–745,790–811` explicitly expect unknown/unlisted ID succeeded+consumed, unusable succeeded+released, and exact wire result. These are existing tests read, not rerun in this audit.
5. **Mismatch:** `ios/Plants/Data/Remote/APIModels.swift:1467–1472` requires unknown (plant=nil) quota released. `ios/PlantsTests/CollectionWireTests.swift:7180–7217` explicitly rejects unknown+consumed at7191. API client `PlantsAPIClient.swift:1987,2004` validates before returning job to service.
6. `ios/Plants/App/PlantsApp.swift:1957–1978`: only succeeded job returns PhotoIdentificationResult and uploadedPhotoId/photoOwnerId; nil species is permitted and does not trigger a published-detail GET. A validation throw happens before this return.
7. `AnalysisFlowModel.swift:658–666`: a returned identification, including nil species, creates correctionSource with original request/job/photo/owner. Lines695–706 map invalidResponse through default to analysis.error.failed. For a fresh failed request there is no successful correctionSource/manual claim selection. The service may still retain private upload/job progress for retry; this is not proof photo bytes were deleted or job failed on server.
8. `PreliminaryResultView.swift:185–238,485–486`: identification result shows undetermined-species heading and manual chooser when source owner matches SDK session. Failure UI at703–755 is a separate retry/back path, not the manual chooser. `FirstHelpUnitTests.swift:788–825` and `CollectionWireTests.swift:16353–16435` inject successful unknown directly, bypassing the server-wire quota gate.

## Claim eligibility

`202611120021_guest_photo_claim.sql:443–470` requires same guest/installation, identification job succeeded, projection identified OR unknown, ready original photo, published manually confirmed taxon, unexpired source. Failed/expired jobs do not satisfy this query. Source and photo IDs must be preserved; choosing a taxon does not make a failed job eligible.

Provider unusable and useful unknown are **indistinguishable by current identification result fields** (same unknown/null), apart from current quota side effect. Current wire has no usable-image reason code. Do not claim the synthetic useful-unknown test proves unusable-photo guidance or classification accuracy.

## “Insufficient information” is not one identification reason code

No literal `insufficient_information` / `insufficient information` found in tracked current source. Actual diagnosis status is `insufficient_data`:
- `AnthropicAdapter.ts:286–315` resolves valid diagnosis classification to a projection (including insufficient_data).
- `ProtocolResolver.ts:397–423` retains diagnosis_status and emits localized insufficient-data limitation, no selected treatment.
- `APIModels.swift:1557–1568` maps insufficient_data to domain DiagnosisStatus.unknown.
- `AnalysisFlowModel.swift:181–218,675–681` displays this as diagnosis uncertainty and retains diagnosisPhoto; it does not create identification correctionSource. This is the diagnosis result path, not B2 identification manual claim. Usable insufficient-data diagnosis is not inherently a failed job.

Actual failed paths: provider refusal/truncation/invalid JSON/timeout => PROVIDER_REFUSAL / PROVIDER_TRUNCATED / PROVIDER_INVALID_JSON / PROVIDER_TIMEOUT_OR_ERROR; malformed schema => SCHEMA_VALIDATION_FAILED; unavailable catalogue/storage can yield ANALYSIS_PROCESSING_FAILED; timeout is distinct expired status. Provider errors in identification become provider_terminal (PlantsApp.swift:1947–1955); non-provider failed statuses become unavailable then generic failed. None returns a successful identification source. Prepared in-memory photo/request retention does not grant server claim eligibility.

## B2 coverage boundary for parent decision

- Useful unknown scenario must cover real wire **succeeded/unknown/null + consumed**, original IDs/owner and job->service->model path; direct injected nil-species success alone misses the existing mismatch. Existing rejection test must be reconciled with chosen server contract through explicit parent authorization; no repair performed here.
- Keep identified-success correction distinct from useful-unknown manual selection and original-photo claim.
- Keep unusable folded-unknown (released) limitation explicit; it is not evidence of a failed-job path.
- Failed provider/schema/expired cases are separate failure/cancel/retry UI coverage; never fabricate correctionSource or successful claim from them.
- Diagnosis insufficient_data is a separate succeeded diagnosis branch, not evidence for identification unknown. Historical “not enough information” copy alone proves neither branch.

No scope changes, new roles, UI execution or source repair performed.

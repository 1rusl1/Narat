BEGIN;

-- Existing claims and receipts remain available for history and sync.
DROP FUNCTION public.claim_notification_slot(UUID, UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ);
DROP FUNCTION public.cancel_notification_claim(UUID, TEXT, TEXT, TIMESTAMPTZ);

COMMIT;

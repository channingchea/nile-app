-- Onboarding gate: null = user has not completed (or skipped through) the
-- post-signup onboarding flow; _AuthGate routes them into OnboardingScreen.
-- Stamped by ProfileService.markOnboarded() as the final onboarding action.
-- No RLS change needed — "profiles: update own" already covers this column.

alter table public.profiles
  add column if not exists onboarded_at timestamptz;

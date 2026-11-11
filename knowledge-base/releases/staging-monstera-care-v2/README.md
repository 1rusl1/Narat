# Staging Monstera care release

This staging release adds one PlantProfile v2 action for Monstera deliciosa and carries forward the existing overwatering condition profile with its content preserved. The catalogue remains independent of the KB activation.

The English and Polish action texts are editorial paraphrases for Narat. The research entry is `/care/watering` in `catalogue/pilot/profiles/monstera_deliciosa.research.json`. The cited fact comes from the watering paragraph in Growing Swiss-Cheese Plant, reviewed 11 November 2026. [UW–Madison Division of Extension](https://hort.extension.wisc.edu/articles/monstera-deliciosa/)

The SHA-256 in the profile is for the following retained UTF-8 evidence note without a trailing newline.

> The Extension article advises thorough watering of indoor Monstera deliciosa after the growing medium has dried slightly since the last watering.

The use basis covers only this derived factual record. Source text, images and raw imports are excluded. A slight dry-down is the condition for watering. The profile supplies no fixed interval.

Render the checked-in release with `python3 tools/automation/render_staging_monstera_care_release.py > /tmp/narat-staging-monstera-care-v2.sql`. Apply the rendered SQL only to narat-staging using `supabase db query --linked --project-ref ijwnyjdomwvnzmmcurkt --file /tmp/narat-staging-monstera-care-v2.sql`. The transaction checks the expected source release and condition content, verifies the published Monstera taxon and retains the old KB for existing jobs.

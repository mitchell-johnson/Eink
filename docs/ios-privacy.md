# Label Studio privacy inventory

This private app sends prompts to its owner's Cloudflare Worker and OpenAI only
when Generate is selected. The Worker uses the Responses API with `store:false`;
that setting is not a claim of zero provider retention. OpenAI's applicable API
data policies and account controls still apply.

The service removes plaintext prompt content after generation finishes. Generated
PNGs stop being accessible 24 hours after the request was created and are deleted
by an alarm; deletion is retried if storage is unavailable. A request UUID, prompt
hash, model, expiry and outcome remain permanently so that an interrupted client
cannot accidentally repeat a paid request. Diagnostic logs record request IDs,
outcomes and safe error codes, never prompts, tokens, keys or image data. Their
retention follows the owner's Cloudflare observability configuration.

The phone stores saved designs locally. Imported photos are converted locally and
are not uploaded. Deleting a local design does not delete the server's request
record. The app's bearer code and label authentication key are stored separately
in Keychain with device-only accessibility while unlocked. The label key is used
only for the local Bluetooth challenge and is never sent to the server. The
OpenAI key is held only in a Cloudflare secret.

The privacy manifest declares Other User Content (free-form prompts/generated
artwork) and Other Diagnostic Data for app functionality, linked to the private
owner context, without tracking. It declares UserDefaults access reason CA92.1
for app-owned settings and pending-request recovery. There is no ad SDK or analytics
SDK. Photo-library collection is not declared because import stays on-device.

Classifying generated illustrations as Other User Content is an interpretation;
Apple explicitly categorizes free-form text that way, but does not provide an
AI-output-specific category. App Store Connect's privacy questionnaire should
match this behavior when the release record is configured.

Sources: [Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/),
[Apple privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests).

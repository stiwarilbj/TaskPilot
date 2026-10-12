# Screen-coordinate mapping

`ScreenCoordinateMapping` owns conversion between screenshot pixels, global
Quartz points, full-display normalized actions, and AppKit cursor coordinates.
The screenshot supplies its actual `CGImage` dimensions. No Retina scale or
requested capture size is assumed.

Each accepted observation carries versioned geometry and native affine
transforms, bound to its display ID and observation revision. Python validates
that metadata before planning and consumes those transforms for target matching.
The native executor checks the bound display and fresh display bounds before
pointer delivery. A changed display requests a fresh observation through the
existing stale-target recovery.

Action coordinates remain 0–1000 across the full display, with x increasing
right and y increasing down. Pixel coordinates describe the presented image.
The mapping composes crop origins and independent resize scales; nested crops
do not change the action coordinate space. This adds no new crop behavior or
user controls. Image edges remain exact for geometric conversion; delivered
events at the inclusive 1000 endpoint are inset half a point to stay on the
assigned display instead of its neighbor.

Capture checks reject changing display geometry and use the existing bounded
local consistency retry. Failed pairs never reach planning. Mapping metadata
adds no provider calls and supplies no missing action targets. Preview size
limits and the current manual viewer behavior remain unchanged.

Task protocol version 4 and the existing generated contract fingerprint reject
old/new bundled component mixtures before task requests. The private startup
configuration also checks coordinate mapping version 1, and decision caches
include that version.

The shared Swift/Python fixture corpus covers Retina and resized images,
negative display origins, displays above the main screen, independent dimension
rounding, and resized/fractional crops. Additional tests cover inverse mapping,
nested crops, edge delivery, invalid geometry, stale metadata, and local capture
retry. All checks are offline; live desktop accuracy remains unverified.

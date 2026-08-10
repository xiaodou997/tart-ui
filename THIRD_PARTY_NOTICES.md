# Third-party notices

## Tart

TartUI bundles and invokes the Tart virtualization runtime from
[openai/tart](https://github.com/openai/tart).

The Tart source and release artifacts are distributed under the
Functional Source License, Version 1.1, ALv2 Future License (FSL-1.1-ALv2).
The original Tart license and copyright notices are preserved in the Tart
submodule at `Vendor/tart/LICENSE` and are included in the application under
`Contents/Resources/Legal/Tart-LICENSE.txt` when a release bundle is built.

TartUI does not keep a fork of the Tart source. During helper compilation it
temporarily applies the small `Resources/tart-agent.patch` integration patch,
then restores the checkout before the build finishes. The exact Tart commit
used by a build is recorded by the `Vendor/tart` Git submodule.

## Tart dependencies

Tart itself depends on the open-source Swift packages recorded in
`Vendor/tart/Package.resolved`. Their respective license notices remain part
of the Tart source distribution and must be reviewed when producing a release.

## Relationship to Tart

TartUI is an independent graphical user interface for Tart. It is not
affiliated with or endorsed by OpenAI. The Tart name and related marks belong
to their respective owners.

# TaskPilot architecture

TaskPilot is split by responsibility, so the folder name tells you why the code exists before you even open a file.

Background prompt changes can be evaluated against private sanitized cases
using the [offline prompt regression workflow](PromptRegression.md). It
exercises the existing runtime without desktop events or provider calls and
keeps reproduction controls distinct from recorded model comparisons.

[Execution-phase prompt compilation](PromptCompilation.md) selects distinct
planning, recovery and completion contracts locally and separates instructions
from canonical task evidence.

[Exact task inputs](TaskInputs.md) retain immutable literal values in task memory
and resolve model references before ordinary action validation and execution.

Task completion is guarded by the runtime's private
[requirement evidence ledger](TaskEvidence.md), including whole-request
coverage and fresh proof for mutable outcomes.

[Native action receipts](ActionReceipts.md) retain task-scoped dispatch and
terminal results so missing acknowledgements can be reconciled without
duplicating execution.

[Deterministic command intentions](CommandOperations.md) compile explicit
operations into shared argument templates with preflight and exact outcome
checks.

[Bounded control compatibility profiles](ControlCompatibility.md) retain
verified delivery methods without retaining control targets or user content.

[Screen-coordinate mapping](ScreenCoordinates.md) binds actual screenshot
pixels, crop geometry, and normalized actions to the accepted display and
observation revision.

[Observation completeness](ObservationCompleteness.md) reports collection gaps
and expands relevant omitted Accessibility branches locally before planning.

[Local text recognition](LocalTextRecognition.md) supplements poorly exposed
controls with provisional Vision word boxes and same-screenshot detail crops.
Text-based coordinate clicks are rechecked natively before delivery.

## The main flow

1. `TaskPilotApp` creates the macOS windows.
2. `TaskPilotMainView` shows the controller interface.
3. `TaskPilotCoordinator` owns setup, task state, queue state, and the app's services.
4. `AgentAutomationBridge` turns runtime requests into validated native actions.
5. `AgentRuntimeProcess` talks to the Python OpenClaw runtime.
6. Platform services capture the screen, find displays, and send notifications.

## Folder map

```text
TaskPilot/
├── TaskPilot.app                Ready-to-open built app
├── README.md                    Friendly setup and project overview
└── ProjectFiles/
    ├── Package.swift            Click this to open the project in Xcode
    ├── AgentRuntime/            Python reasoning loop
    ├── Documentation/           Architecture notes and README images
    ├── Resources/OpenClaw/      OpenClaw setup helpers bundled with the app
    ├── Scripts/                 Build, run, runtime packaging, and signing
    ├── Sources/OrbitAgent/
    │   ├── Application/         App entry point, identity, and coordination
    │   ├── UserInterface/       Main window, settings, history, and live screen
    │   ├── Agent/Automation/    Validated macOS actions and native tools
    │   ├── Agent/Runtime/       Swift-to-Python bridge and OpenClaw lifecycle
    │   ├── Platform/            Capture, displays, and notifications
    │   └── Persistence/         Credentials, queue, and task history
    └── Tests/                   Swift, Python, integration tests, and fixtures
```

## Naming rules

Private target context and delivery checks are described in [Target relationships](TargetRelationships.md).
Local postconditions and read-only checks are described in [Executable expected results](ExpectedEffects.md).

- Types say what they own or do. `TaskPilotCoordinator` coordinates the app, while `TaskToolExecutor` executes native tools.
- Views describe the screen they render, such as `TaskQueueHistoryView`.
- Services describe the system they wrap, such as `ScreenCaptureService` and `OpenClawService`.
- Compatibility names remain only where changing them would break saved settings, permissions, signing, or an existing virtual display.

## Compatibility that stays on purpose

The Swift package and executable are still named `OrbitAgent`, the bundle ID is still `com.orbitagent.controller`, and the existing BetterDisplay screen is still `Orbit Agent Screen`. Those are stable technical identities. The public product name is TaskPilot.

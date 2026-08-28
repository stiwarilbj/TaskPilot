# TaskPilot architecture

TaskPilot is split by responsibility, so the folder name tells you why the code exists before you even open a file.

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

- Types say what they own or do. `TaskPilotCoordinator` coordinates the app, while `TaskToolExecutor` executes native tools.
- Views describe the screen they render, such as `TaskQueueHistoryView`.
- Services describe the system they wrap, such as `ScreenCaptureService` and `OpenClawService`.
- Compatibility names remain only where changing them would break saved settings, permissions, signing, or an existing virtual display.

## Compatibility that stays on purpose

The Swift package and executable are still named `OrbitAgent`, the bundle ID is still `com.orbitagent.controller`, and the existing BetterDisplay screen is still `Orbit Agent Screen`. Those are stable technical identities. The public product name is TaskPilot.

# Design tokens

Status: Focus implemented under owner-delegated PM selection, 2026-09-12.

Owner: `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote/ContentSharedUIComponents.swift`. These supplement SwiftUI system typography and native navigation/Form controls.

| Token | Light | Dark | Purpose |
| --- | --- | --- | --- |
| `FocusStyle.background` | `systemGroupedBackground` | System mapping | Screen canvas |
| `FocusStyle.surface` | `secondarySystemGroupedBackground` | System mapping | Information surfaces |
| `FocusStyle.accent` | RGB 0.70, 0.28, 0.00 | RGB 1.00, 0.67, 0.40 | Start, progress, selection |
| `FocusStyle.actionText` | White | RGB 0.15, 0.06, 0.00 | Text on filled action buttons |
| `FocusStyle.stop` | RGB 0.75, 0.16, 0.21 | RGB 1.00, 0.45, 0.51 | Stop and HR symbol |
| `FocusStyle.secondaryText` | White 0.32 | White 0.72 | Readable supporting text on authored surfaces |
| `FocusStyle.cornerRadius` | 24 pt | 24 pt | Information cards |
| `FocusActionStyle` | 18 pt radius, minimum 56 pt height | Same | Primary action and Stop |

Spacing uses 4/8/12/16/20/24-point increments. Normal HR is a scalable rounded 72-point value; accessibility sizes use the rounded large-title style, with a compact baseline unit. Other authored content uses semantic text styles and monospaced digits. The fixed lower dock adapts its axis before reducing available reading space; it does not cap the user's Dynamic Type category.

Physiological zone hues preserve their existing meaning. Text labels and markers carry selection/HR meaning independently of color. Cards use solid semantic surfaces, so Reduce Transparency does not depend on recreating a custom material. Native system controls retain their own platform appearance.

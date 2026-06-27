#!/usr/bin/env python3
import unittest

from analyze_training_log import Row, collect_diagnostic_observations


class DiagnosticObservationTests(unittest.TestCase):
    def test_device_distance_alone_does_not_produce_physical_verdict(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-28T00:00:00Z",
                t=0.0,
                session="s1",
                event="treadmill_test_started",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "30",
                    "command_native_units": "imperial",
                    "command_native_speed": "3.0",
                    "distance_km": "0.000",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
            Row(
                index=1,
                ts_raw="2026-06-28T00:01:00Z",
                t=60.0,
                session="s1",
                event="treadmill_test_finished",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "30",
                    "command_native_units": "imperial",
                    "command_native_speed": "3.0",
                    "distance_km": "0.081",
                    "distance_raw": "30",
                    "distance_raw_units_unknown": "true",
                    "distance_unit_pref": "imperial",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
            Row(
                index=2,
                ts_raw="2026-06-28T00:01:30Z",
                t=90.0,
                session="s1",
                event="treadmill_test_finished",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "0",
                    "command_native_units": "imperial",
                    "command_native_speed": "0",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
        ]

        observations = collect_diagnostic_observations(rows)

        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0].command_raw_tenths, "30")
        self.assertEqual(observations[0].command_native_speed, "3.0")
        self.assertEqual(observations[0].verdict, "inconclusive_without_external_measurement")
        self.assertEqual(observations[0].device_distance_raw_delta, 30.0)
        self.assertIsNone(observations[0].external_distance_m)

    def test_external_distance_can_produce_physical_verdict(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-28T00:00:00Z",
                t=0.0,
                session="s1",
                event="treadmill_test_started",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "30",
                    "command_native_units": "imperial",
                    "command_native_speed": "3.0",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
            Row(
                index=1,
                ts_raw="2026-06-28T00:01:00Z",
                t=60.0,
                session="s1",
                event="treadmill_test_finished",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "0",
                    "command_native_units": "imperial",
                    "command_native_speed": "0",
                    "external_distance_m": "81.0",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
        ]

        observations = collect_diagnostic_observations(rows)

        self.assertEqual(observations[0].verdict, "physical_likely_mph")
        self.assertEqual(observations[0].external_distance_m, 81.0)


if __name__ == "__main__":
    unittest.main()

import subprocess
import unittest
from unittest.mock import Mock

from keychain_integration import cleanup_items


class CleanupTests(unittest.TestCase):
    def test_timeout_does_not_skip_remaining_scopes(self):
        run = Mock(
            side_effect=[
                subprocess.TimeoutExpired("delete", 20),
                subprocess.CompletedProcess([], 0, b"", b""),
            ]
        )
        with self.assertRaisesRegex(RuntimeError, "scopes \\['icloud'\\]"):
            cleanup_items(run, {"local", "icloud"}, "test-service", "dummy")
        self.assertEqual(
            [call.args[2] for call in run.call_args_list], ["icloud", "local"]
        )

    def test_launch_failure_does_not_skip_remaining_scopes(self):
        run = Mock(
            side_effect=[
                FileNotFoundError(),
                subprocess.CompletedProcess([], 0, b"", b""),
            ]
        )
        with self.assertRaisesRegex(RuntimeError, "test-service"):
            cleanup_items(run, {"local", "icloud"}, "test-service", "dummy")
        self.assertEqual(run.call_count, 2)

    def test_not_found_is_already_clean_but_auth_failure_is_not(self):
        run = Mock(
            return_value=subprocess.CompletedProcess([], 1, b"", b"Error: ItemNotFound")
        )
        cleanup_items(run, {"local"}, "test-service", "dummy")
        run.return_value = subprocess.CompletedProcess([], 1, b"", b"Error: AuthFailed")
        with self.assertRaisesRegex(RuntimeError, "local"):
            cleanup_items(run, {"local"}, "test-service", "dummy")


if __name__ == "__main__":
    unittest.main()

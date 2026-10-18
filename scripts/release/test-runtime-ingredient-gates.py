#!/usr/bin/env python3
"""Check that branch preparation cannot enter final runtime publication."""
import ast
import itertools
from pathlib import Path
import re
import unittest


class RuntimeIngredientGateTests(unittest.TestCase):
    def test_event_and_source_boundaries(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/runtime-ingredients.yml").read_text()
        jobs = {name: body for name, body in re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:|\Z)", workflow, re.M | re.S)}
        for main, official, event, ingredients, sdk_available in itertools.product(
                (False, True), (False, True), ("push", "pull_request", "workflow_dispatch"), (False, True), (False, True)):
            values = {"github.ref": "refs/heads/main" if main else "refs/heads/fix/pin-update",
                      "github.repository": "hostwright/hostwright" if official else "example/fork",
                      "github.event_name": event, "inputs.ingredients_only": ingredients,
                      "inputs.sdk_checkpoint_run": "1234" if sdk_available else "",
                      "needs.source-built-swift-sdk.result": "skipped",
                      "needs.swift-sdk-evidence.result": "success",
                      "needs.runtime-build-ingredients.result": "success",
                      "needs.guest-loader.result": "success"}
            expected = {
                "source-built-swift-sdk": main and event == "workflow_dispatch" and not sdk_available,
                "swift-sdk-evidence": event == "workflow_dispatch" and sdk_available and (main or (official and ingredients)),
                "runtime-build-ingredients": event == "workflow_dispatch" and (main or (official and ingredients)),
                "guest-loader": main or (official and event == "workflow_dispatch" and ingredients),
                "runtime-provenance": main and event == "workflow_dispatch" and not ingredients,
            }
            for job, allowed in expected.items():
                expression = re.search(r"^    if: \$\{\{ (.*?) \}\}$", jobs[job], re.M).group(1)
                for key in sorted(values, key=len, reverse=True):
                    expression = expression.replace(key, repr(values[key]))
                expression = expression.replace("always()", "True").replace("&&", " and ").replace("||", " or ")
                expression = re.sub(r"\btrue\b", "True", expression)
                expression = re.sub(r"\bfalse\b", "False", expression)
                tree = ast.parse(expression, mode="eval")
                self.assertTrue(all(isinstance(node, (ast.Expression, ast.BoolOp, ast.And, ast.Or,
                                                       ast.Compare, ast.Eq, ast.NotEq, ast.Constant))
                                    for node in ast.walk(tree)))
                with self.subTest(job=job, main=main, official=official, event=event,
                                  ingredients=ingredients, sdk_available=sdk_available):
                    self.assertEqual(eval(compile(tree, "<ingredient-gate>", "eval"), {"__builtins__": {}}), allowed)


if __name__ == "__main__":
    unittest.main()

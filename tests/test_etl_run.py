"""docker/etl-run.py: the DGBF's yearly budget file and where its step runs.

    docker run --rm -v "$PWD":/repo -w /repo --entrypoint python \\
      boost-togo/pipeline:<release> -m unittest discover tests
"""
import importlib.machinery
import importlib.util
import math
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("etl_run", os.path.join(HERE, "..", "docker", "etl-run.py"))
_spec = importlib.util.spec_from_loader("etl_run", _loader)
etl_run = importlib.util.module_from_spec(_spec)
_loader.exec_module(etl_run)


def read(text):
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, encoding="utf-8") as f:
        f.write(text)
    try:
        return etl_run.read_togo_fiscal(f.name)
    finally:
        os.unlink(f.name)


class ReadTogoFiscalTest(unittest.TestCase):
    def test_semicolons_decimal_commas_and_no_tax_expenditure(self):
        rows = read("annee;recettes;depenses;depenses_fiscales\n"
                    "2024;1336,1;1674,2;\n2023;1 326,7;1643,0;\n")
        self.assertEqual(list(rows["year"]), [2023, 2024])
        self.assertEqual(list(rows["revenue_current_lcu"]), [1326.7e9, 1336.1e9])
        self.assertEqual(list(rows["expenditure_current_lcu"]), [1643.0e9, 1674.2e9])
        self.assertTrue(all(math.isnan(v) for v in rows["tax_expenditure"]))
        self.assertEqual(set(rows["data_source"]), {"Togo DGBF"})
        self.assertEqual(set(rows["country_name"]), {"Togo"})

    def test_commas_with_tax_expenditure_and_source(self):
        rows = read("Annee,Recettes,Depenses,Depenses_fiscales,Source\n"
                    "2022,1051.36,1432.88,160.34,Rapport d'exécution 2022\n")
        row = rows.iloc[0]
        self.assertEqual(row["tax_expenditure"], 160.34e9)
        self.assertEqual(row["data_source"], "Rapport d'exécution 2022")

    def test_amounts_are_whole_francs(self):
        row = read("annee;recettes;depenses;depenses_fiscales\n2021;921,58;1137,29;135,80\n").iloc[0]
        self.assertEqual(row["tax_expenditure"], 135_800_000_000)
        self.assertEqual(row["revenue_current_lcu"], 921_580_000_000)
        self.assertEqual(row["expenditure_current_lcu"], 1_137_290_000_000)

    def test_missing_column(self):
        with self.assertRaisesRegex(ValueError, "missing column.*depenses"):
            read("annee;recettes\n2025;1381,7\n")

    def test_amount_that_is_not_a_number(self):
        with self.assertRaisesRegex(ValueError, "recettes is not a number: 1381,7 Md"):
            read("annee;recettes;depenses\n2025;1381,7 Md;1604,9\n")

    def test_empty_spending(self):
        with self.assertRaisesRegex(ValueError, "depenses is empty for 2025"):
            read("annee;recettes;depenses\n2025;1381,7;\n")

    def test_year_given_twice(self):
        with self.assertRaisesRegex(ValueError, "year\\(s\\) given twice: 2025"):
            read("annee;recettes;depenses\n2025;1;2\n2025;3;4\n")


class StepOrderTest(unittest.TestCase):
    def test_file_step_runs_right_after_the_notebook_it_replaces(self):
        notebook = etl_run.TOGO_FISCAL_NOTEBOOK.split("/", 1)[1]
        with mock.patch.object(etl_run, "notebooks", return_value=["gdp.py", notebook, "country.py"]):
            names = [name for name, _, _ in etl_run.steps()]
        position = names.index(etl_run.TOGO_FISCAL_NOTEBOOK)
        self.assertEqual(names[position + 1], "inputs/togo_revenue_budget")

    def test_missing_file_keeps_the_table(self):
        with mock.patch.object(etl_run, "TOGO_FISCAL_FILE", "/nonexistent/solde_budgetaire.csv"):
            self.assertEqual(etl_run.load_togo_fiscal(), "skipped")


if __name__ == "__main__":
    unittest.main()

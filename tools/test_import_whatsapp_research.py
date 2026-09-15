import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

import import_whatsapp_research as importer


class ImportPublicationTests(unittest.TestCase):
    def test_concurrent_output_is_preserved_unless_replace_is_explicit(self):
        for replace in (False, True):
            with self.subTest(replace=replace), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive, output = root / "fixture.zip", root / "result.json"
                with ZipFile(archive, "w") as bundle:
                    bundle.writestr("chat.txt", "[9/3/26, 10:00:00 PM] Person: RKLB research")
                original_parse = importer.parse_export

                def concurrent_import(*args):
                    output.write_bytes(b"earlier completed import")
                    return original_parse(*args)

                arguments = ["import", str(archive), "--output", str(output)]
                if replace:
                    arguments.append("--replace")
                with patch("sys.argv", arguments), patch.object(importer, "parse_export", concurrent_import), \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    if replace:
                        importer.main()
                        self.assertEqual(json.loads(output.read_bytes())["messages"][0]["text"], "RKLB research")
                    else:
                        with self.assertRaises(SystemExit) as error:
                            importer.main()
                        self.assertEqual(error.exception.code, 2)
                        self.assertEqual(output.read_bytes(), b"earlier completed import")
                self.assertEqual(list(root.glob(".whatsapp-*")), [])


if __name__ == "__main__":
    unittest.main()

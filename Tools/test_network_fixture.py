import contextlib,importlib.util,json,pathlib,subprocess,sys,tempfile,unittest,urllib.request,zipfile
TOOLS=pathlib.Path(__file__).parent
class NetworkFixtureTests(unittest.TestCase):
    def test_stored_archive_and_loopback_server(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);fixture=root/'fixture';fixture.mkdir()
            manifest={'id':'org.notchframework.hello','name':'Hello','version':'0.1.0','entrypoint':'hello','files':['hello'],'protocolVersion':1}
            (fixture/'manifest.json').write_text(json.dumps(manifest));(fixture/'hello').write_bytes(b'fixture data; never executed')
            archive=root/'hello.zip'
            subprocess.run([sys.executable,str(TOOLS/'build-stored-archive.py'),str(fixture),str(archive)],check=True)
            with zipfile.ZipFile(archive) as z:
                self.assertEqual(set(z.namelist()),{'manifest.json','hello'})
                self.assertTrue(all(x.compress_type==zipfile.ZIP_STORED and not x.extra and not x.comment for x in z.infolist()))
            server=subprocess.Popen([sys.executable,'-u',str(TOOLS/'fixture-http.py'),str(root)],stdout=subprocess.PIPE,text=True)
            try:
                port=int(server.stdout.readline().strip())
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/hello.zip',timeout=3) as response:
                    self.assertEqual(response.read(),archive.read_bytes())
            finally:
                server.terminate();server.wait(timeout=3);server.stdout.close()
    def test_cross_language_fixture_shape(self):
        path=TOOLS.parent/'Tests/NotchExtensionCoreTests/Fixtures/python-signed-catalog.json'
        import base64
        e=json.loads(path.read_text());payload=json.loads(base64.b64decode(e['payload']))
        self.assertEqual(e['keyID'],'RFC8032-TEST-ONLY');self.assertEqual(len(base64.b64decode(e['signature'])),64)
        self.assertEqual(payload['catalogVersion'],1)
        self.assertEqual(payload['entries'],[])
if __name__=='__main__':unittest.main()

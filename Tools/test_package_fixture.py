import importlib.util,json,pathlib,stat,tempfile,unittest,zipfile
p=pathlib.Path(__file__).with_name('package_fixture.py');spec=importlib.util.spec_from_file_location('package',p);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
class PackageTests(unittest.TestCase):
    def setUp(self): self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.archive=self.root/'test.zip'
    def tearDown(self):self.tmp.cleanup()
    def write(self,extras=None,manifest=None):
        m=manifest or {'id':'org.test.hello','name':'Hello','version':'0.1.0','entrypoint':'hello','files':['hello'],'protocolVersion':1}
        with zipfile.ZipFile(self.archive,'w') as z:
            z.writestr('manifest.json',json.dumps(m));z.writestr('hello',b'not executed')
            for name,data in (extras or []): z.writestr(name,data)
    def test_extract_no_execution(self):
        self.write(); dest=self.root/'out';mod.extract(self.archive,dest);self.assertEqual((dest/'hello').read_bytes(),b'not executed')
    def test_traversal(self):
        for name in ('../escape','/tmp/escape','a/../../escape','a\\escape','a//b','./hello'):
            with self.subTest(name=name):
                self.write([(name,b'bad')])
                with self.assertRaises(ValueError):mod.extract(self.archive,self.root/'out')
                self.assertFalse((self.root/'out').exists())
    def test_symlink(self):
        self.write()
        with zipfile.ZipFile(self.archive,'a') as z:
            i=zipfile.ZipInfo('link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(i,'/tmp')
        with self.assertRaises(ValueError):mod.inspect(self.archive)
    def test_undeclared(self):
        self.write([('extra',b'x')])
        with self.assertRaises(ValueError):mod.inspect(self.archive)
    def test_case_collision(self):
        self.write([('HELLO',b'x')])
        with self.assertRaises(ValueError):mod.inspect(self.archive)
    def test_existing_destination(self):
        self.write();dest=self.root/'out';dest.mkdir()
        with self.assertRaises(ValueError):mod.extract(self.archive,dest)
    def test_bomb_ratio(self):
        with zipfile.ZipFile(self.archive,'w',compression=zipfile.ZIP_DEFLATED) as z:z.writestr('huge',b'0'*1000000)
        with self.assertRaisesRegex(ValueError,'ratio'):mod.inspect(self.archive)
if __name__=='__main__':unittest.main()

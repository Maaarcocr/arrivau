import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pilot_config', ROOT/'scripts/validate-pilot-config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

bundle_spec = importlib.util.spec_from_file_location('verify_bundle', ROOT/'scripts/verify-ios-bundle.py')
bundle_module = importlib.util.module_from_spec(bundle_spec)
bundle_spec.loader.exec_module(bundle_module)

class PilotConfigurationTests(unittest.TestCase):
    def test_https_origins(self):
        for endpoint in ['https://pilot.example.com', 'https://pilot.example.com/', 'https://pilot.example.com:8443', 'https://192.168.1.4:443']:
            self.assertEqual(config.validate_endpoint(endpoint), endpoint.rstrip('/'))

    def test_invalid_origins(self):
        for endpoint in ['', 'http://pilot.example.com', 'https://localhost', 'https://LOCALHOST.', 'https://sub.localhost', 'https://foo.local', 'https://127.0.0.1', 'https://[::1]', 'https://0.0.0.0', 'https://[::]', 'https://169.254.1.2', 'https://224.0.0.1', 'https://foo:secret@pilot.example.com', 'https://pilot.example.com/v1', 'https://pilot.example.com?secret=x', 'https://pilot.example.com#fragment', 'https://pilot.example.com:0', 'https://pilot.example.com:99999', 'https://pilot.example.com\\other', 'https://pilot .example.com', '$(ARRIVAU_API_URL)']:
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                config.validate_endpoint(endpoint)

    def test_archive_requires_real_non_secret_configuration(self):
        env = {'ARRIVAU_API_URL': 'https://pilot.example.com', 'ARRIVAU_TEAM_ID': 'ABCDEFGHIJ', 'ARRIVAU_BUNDLE_ID': 'com.example.arrivau', 'ARRIVAU_BUILD_NUMBER': '1'}
        config.validate_archive(env)
        for key in env:
            with self.subTest(key=key), self.assertRaises(ValueError):
                config.validate_archive({**env, key: ''})
        with self.assertRaises(ValueError):
            config.validate_archive({**env, 'ARRIVAU_BUNDLE_ID': 'dev.arrivau.app'})

    def test_release_has_no_insecure_transport_exception(self):
        info = plistlib.loads((ROOT/'ios/Config/Info-Release.plist').read_bytes())
        self.assertNotIn('NSAppTransportSecurity', info)
        self.assertEqual(info['ARRIVAU_API_URL'], '$(ARRIVAU_API_URL)')
        self.assertEqual(info['CFBundleVersion'], '$(CURRENT_PROJECT_VERSION)')
        self.assertEqual(info['CFBundleShortVersionString'], '$(MARKETING_VERSION)')

    def test_icon_is_complete_opaque_1024_png(self):
        folder = ROOT/'ios/Resources/Assets.xcassets/AppIcon.appiconset'
        manifest = json.loads((folder/'Contents.json').read_text())
        data = (folder/manifest['images'][0]['filename']).read_bytes()
        self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
        width,height,depth,color = struct.unpack('>IIBB', data[16:26])
        self.assertEqual((width,height,depth,color), (1024,1024,8,2))

    def test_release_bundle_verifier_rejects_missing_resources_and_demo_tokens(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp)
            info = {'CFBundleExecutable': 'Arrivau', 'UIDeviceFamily': [1],
                    'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}},
                    'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.2.0'}
            (bundle/'Info.plist').write_bytes(plistlib.dumps(info))
            (bundle/'Arrivau').write_bytes(b'release binary fixture')
            (bundle/'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False}))
            with self.assertRaises(ValueError):
                bundle_module.verify(bundle)
            (bundle/'Assets.car').write_bytes(b'compiled asset fixture')
            self.assertTrue(bundle_module.verify(bundle))
            for token in (b'demo-dispatcher', b'demo-driver-1', b'demo-driver-2', b'demo-dual'):
                with self.subTest(token=token):
                    (bundle/'Arrivau').write_bytes(b'prefix ' + token + b' suffix')
                    with self.assertRaises(ValueError):
                        bundle_module.verify(bundle)

    def test_privacy_manifest(self):
        manifest = plistlib.loads((ROOT/'ios/Resources/PrivacyInfo.xcprivacy').read_bytes())
        self.assertFalse(manifest['NSPrivacyTracking'])
        self.assertEqual(manifest['NSPrivacyAccessedAPITypes'], [])

if __name__ == '__main__':
    unittest.main()

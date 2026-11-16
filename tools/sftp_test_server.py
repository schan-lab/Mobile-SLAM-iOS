# Test SFTP server for MobileSLAMUITests.testSftpUpload (needs: pip install asyncssh).
# Usage: python3 tools/sftp_test_server.py ROOT KEYFILE PORT
#   user "tester"; KEYFILE (re-read on every login) holds the app's public key; files land under ROOT.
#   Run the test with TEST_RUNNER_SFTP_PORT=PORT TEST_RUNNER_SFTP_KEY_FILE=KEYFILE and copy the simulator
#   clipboard into KEYFILE meanwhile, e.g. a loop of: xcrun simctl pbpaste booted > KEYFILE
import asyncio, os, sys
import asyncssh

ROOT, KEYFILE, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])

class Server(asyncssh.SSHServer):
    def begin_auth(self, username):
        return True
    def public_key_auth_supported(self):
        return True
    def validate_public_key(self, username, key):
        if username != "tester" or not os.path.exists(KEYFILE):
            return False
        allowed = asyncssh.import_public_key(open(KEYFILE).read().strip())
        ok = allowed.public_data == key.public_data
        print("auth", username, ok, flush=True)
        return ok

async def main():
    hostkey = asyncssh.generate_private_key("ssh-ed25519")
    await asyncssh.create_server(Server, "127.0.0.1", PORT, server_host_keys=[hostkey],
                                 sftp_factory=lambda chan: asyncssh.SFTPServer(chan, chroot=ROOT))
    print("listening", PORT, flush=True)
    await asyncio.Future()

asyncio.run(main())

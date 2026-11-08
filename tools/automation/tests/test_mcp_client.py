"""MCP transport fixtures only; these tests do not operate Simulator."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcp_client import MCPError, StdioMCP
from doctor import RUNS


SERVER = r'''
import json,sys,time
mode=sys.argv[1]
for line in sys.stdin:
    m=json.loads(line)
    if 'method' not in m or 'id' not in m: continue
    method=m['method']
    if mode=='timeout': time.sleep(30)
    if mode=='eof': sys.exit(0)
    if mode=='invalid': print('not-json',flush=True); continue
    if method=='initialize':
        result={'protocolVersion':'wrong' if mode=='protocol' else '2025-06-18',
                'capabilities':{},'serverInfo':{'name':'fixture','version':'1'}}
    elif method=='tools/list':
        if mode=='rpc-error':
            print(json.dumps({'jsonrpc':'2.0','id':m['id'],'error':{'code':-1,'message':'fixture failure'}}),flush=True);continue
        result={'tools':[{'name':'fixture_tool','inputSchema':{'type':'object'}}]}
        if mode=='cursor': result['nextCursor']='repeated'
    else:
        result={'content':[{'type':'text','text':'fixture output'}]}
        if mode=='tool-error': result['isError']=True
    if mode=='notifications':
        print(json.dumps({'jsonrpc':'2.0','method':'notifications/message','params':{}}),flush=True)
        print(json.dumps({'jsonrpc':'2.0','id':'server-ping','method':'ping'}),flush=True)
    print(json.dumps({'jsonrpc':'2.0','id':m['id']+1 if mode=='wrong-id' else m['id'],'result':result}),flush=True)
'''


class MCPTests(unittest.TestCase):
    def setUp(self):
        RUNS.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="mcp-fixture-", dir=RUNS)

    def tearDown(self):
        self.scratch.cleanup()

    def client(self, mode):
        return StdioMCP("fixture", self.scratch.name, [sys.executable, "-u", "-c", SERVER, mode])

    def test_handshake_discovery_call_and_shutdown(self):
        with self.client("ok") as client:
            self.assertEqual(client.initialize()["serverInfo"]["name"], "fixture")
            self.assertEqual(client.tools()[0]["name"], "fixture_tool")
            self.assertEqual(client.call("fixture_tool", {})["content"][0]["text"], "fixture output")
        self.assertIsNotNone(client.process.poll())

    def test_notifications_and_server_ping_do_not_replace_response(self):
        with self.client("notifications") as client:
            client.initialize()
            self.assertEqual(len(client.tools()), 1)

    def test_rpc_error_is_not_success(self):
        with self.client("rpc-error") as client:
            client.initialize()
            with self.assertRaises(MCPError): client.tools()

    def test_tool_error_is_not_success(self):
        with self.client("tool-error") as client:
            client.initialize()
            with self.assertRaises(MCPError): client.call("fixture_tool", {})

    def test_malformed_wrong_id_protocol_and_eof_are_rejected(self):
        for mode in ("invalid", "wrong-id", "protocol", "eof"):
            with self.subTest(mode=mode), self.client(mode) as client:
                with self.assertRaises(MCPError): client.initialize()

    def test_timeout_is_bounded_and_server_is_stopped(self):
        with self.client("timeout") as client:
            with self.assertRaises(MCPError): client.request("initialize", timeout=0.05)
        self.assertIsNotNone(client.process.poll())

    def test_repeated_pagination_cursor_is_rejected(self):
        with self.client("cursor") as client:
            client.initialize()
            with self.assertRaises(MCPError): client.tools()


if __name__ == "__main__":
    unittest.main()

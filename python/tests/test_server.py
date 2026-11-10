import os
import queue
import socket
import threading
import time
import unittest

import struct

import fake_poser
from ex_poser_bridge import codec, erlterms
from ex_poser_bridge.codec import atom
from ex_poser_bridge.policy import Policy
from ex_poser_bridge.server import Server

MINI = os.path.join(os.path.dirname(__file__), "fixtures", "mini_api.json")
A_R, A_E, A_M = atom("r"), atom("e"), atom("M")
TOKEN = "t0ken"


class _Main(object):
    """Plays Poser's main thread: drains submitted work in a daemon thread."""

    def __init__(self):
        self.work = queue.Queue()
        self.stopped = False
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while not self.stopped:
            try:
                fn = self.work.get(timeout=0.05)
            except queue.Empty:
                continue
            fn()


class ServerTest(unittest.TestCase):
    def start(self, policy=None, port=0):
        self.poser = fake_poser.install()
        self.main = _Main()
        server = Server(["127.0.0.1"], port, TOKEN, self.main.work.put,
                        {"poser_version": "fake-14", "python_version": "3.7.9"},
                        log=lambda m: None, poser=self.poser, policy=policy)
        server.start()
        self.poser.on_new_scene = lambda: self.main.work.put(server.new_generation)
        self.addCleanup(server.stop)
        self.addCleanup(setattr, self.main, "stopped", True)
        return server

    def connect(self, server):
        s = socket.create_connection(("127.0.0.1", server.port), timeout=5)
        self.addCleanup(s.close)
        codec.write_frame(s, (atom("hello"), {atom("token"): TOKEN, atom("protocol"): 1,
                                              atom("client"): "test"}))
        return s, codec.read_frame(s)

    def call(self, s, term):
        codec.write_frame(s, term)
        return codec.read_frame(s)

    def test_hello_reports_mode_and_api_hash(self):
        _, reply = self.connect(self.start(Policy.load("strict", MINI)))
        self.assertEqual(reply[:2], (A_R, 0))
        self.assertEqual(reply[2][atom("mode")], atom("strict"))
        self.assertEqual(reply[2][atom("api_hash")], "mini")
        self.assertEqual(reply[2][atom("protocol")], 1)

    def test_dev_hello_without_dump(self):
        _, reply = self.connect(self.start())
        self.assertEqual(reply[2][atom("mode")], atom("dev"))
        self.assertIsNone(reply[2][atom("api_hash")])

    def test_call_round_trip_over_socket(self):
        s, _ = self.connect(self.start())
        r = self.call(s, (atom("C"), 1, "Scene", [], {}))
        self.assertEqual(r[0], A_R)
        self.assertEqual(r[2][1], "SceneType")

    def test_ping_answered_while_main_blocked(self):
        s, _ = self.connect(self.start())
        codec.write_frame(s, (atom("C"), 1, "Sleep", [1.0], {}))
        time.sleep(0.05)
        t0 = time.time()
        codec.write_frame(s, (atom("ping"), 2))
        first = codec.read_frame(s)
        self.assertEqual(first, (A_R, 2, atom("pong")))
        self.assertLess(time.time() - t0, 0.3)
        self.assertEqual(codec.read_frame(s), (A_R, 1, None))

    def test_generation_change_stales_handles_and_emits_event(self):
        server = self.start()
        s, _ = self.connect(server)
        h = self.call(s, (atom("C"), 1, "Scene", [], {}))[2]
        self.assertEqual(self.call(s, (atom("X"), 2, "fake_poser", "NewScene", [])), (A_R, 2, None))
        self.assertEqual(codec.read_frame(s), (A_M, (atom("generation_changed"), 1)))
        self.assertEqual(server.current_generation(), 1)
        r = self.call(s, (atom("I"), 3, h, "Frame", [], {}))
        self.assertEqual(r, (A_E, 3, (atom("stale_handle"), h[2], 0)))

    def test_unencodable_reply_becomes_error(self):
        s, _ = self.connect(self.start())
        real = codec.encode

        def flaky(term):
            if type(term) is tuple and term[:2] == (A_R, 7):
                raise TypeError("cannot encode this")
            return real(term)

        codec.encode = flaky
        self.addCleanup(setattr, codec, "encode", real)
        r = self.call(s, (atom("C"), 7, "AppVersion", [], {}))
        self.assertEqual(r[:2], (A_E, 7))
        self.assertEqual(r[2][:3], (atom("python"), "EncodeError", "cannot encode this"))

    def test_nan_parameter_value_arrives_as_atom(self):
        s, _ = self.connect(self.start())
        r = self.call(s, (atom("B"), 1, [
            (atom("C"), "Scene", [], {}),
            (atom("I"), (atom("result"), 0), "Actor", ["hip"], {}),
            (atom("I"), (atom("result"), 1), "Parameter", ["Weird"], {}),
            (atom("I"), (atom("result"), 2), "Value", [], {})]))
        self.assertEqual(r[2][3], atom("nan"))

    def test_handle_from_another_connection_is_stale(self):
        server = self.start()
        a, _ = self.connect(server)
        b, _ = self.connect(server)
        h = self.call(a, (atom("C"), 1, "Scene", [], {}))[2]
        scene_b = self.call(b, (atom("C"), 1, "Scene", [], {}))[2]
        self.call(b, (atom("I"), 2, scene_b, "Actor", ["hip"], {}))
        r = self.call(b, (atom("I"), 3, h, "Name", [], {}))
        self.assertEqual(r[2][0], atom("stale_handle"))

    def test_handle_ids_do_not_restart_at_one(self):
        s, _ = self.connect(self.start())
        h = self.call(s, (atom("C"), 1, "Scene", [], {}))[2]
        self.assertNotEqual(h[2], 1)

    def send_raw(self, s, data):
        s.sendall(struct.pack(">I", len(data)) + data)

    def test_undecodable_argument_is_bad_request_not_disconnect(self):
        s, _ = self.connect(self.start())
        # a binary that is not UTF-8, so it cannot become a Python str
        self.send_raw(s, erlterms.encode((atom("C"), 9, b"AppVersion", [b"\xff\xfe"], {})))
        r = codec.read_frame(s)
        self.assertEqual(r[:2], (A_E, 9))
        self.assertEqual(r[2][0], atom("bad_request"))
        self.assertEqual(self.call(s, (atom("ping"), 10)), (A_R, 10, atom("pong")))

    def test_garbage_frame_keeps_connection(self):
        s, _ = self.connect(self.start())
        self.send_raw(s, b"\x83\x99garbage")
        self.assertEqual(self.call(s, (atom("ping"), 11)), (A_R, 11, atom("pong")))

    def test_stats_op(self):
        s, _ = self.connect(self.start())
        self.call(s, (atom("C"), 1, "Scene", [], {}))
        self.assertEqual(self.call(s, (atom("S"), 2)), (A_R, 2, {"handles": 1, "generation": 0}))

    def test_stop_frees_port(self):
        server = self.start()
        port = server.port
        self.assertNotEqual(port, 0)
        server.stop()
        again = Server(["127.0.0.1"], port, TOKEN, lambda fn: None, log=lambda m: None)
        again.start()
        again.stop()


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import argparse
import collections
import json
import math
import os
import queue
import shutil
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
from datetime import datetime, timezone
from pathlib import Path


APP_NAME = "MeetingAssistant"
SAMPLE_RATE = 16_000
ROOT = Path(os.getenv("LOCALAPPDATA", Path.home())) / APP_NAME
MEETINGS = ROOT / "Meetings"
SETTINGS_FILE = ROOT / "settings.json"


def timestamp(seconds: float) -> str:
    value = max(0, int(seconds))
    return f"{value // 3600:02d}:{value // 60 % 60:02d}:{value % 60:02d}"


def remove_overlap(previous: str, candidate: str) -> str:
    previous, candidate = previous.strip(), candidate.strip()
    if not previous or not candidate:
        return candidate
    if previous == candidate or previous.endswith(candidate):
        return ""
    for length in range(min(len(previous), len(candidate)), 1, -1):
        if previous[-length:] == candidate[:length]:
            return candidate[length:].strip()
    return candidate


def safe_filename(value: str) -> str:
    return "".join("-" if char in '<>:"/\\|?*' else char for char in value).strip() or "会议记录"


class MeetingStore:
    def __init__(self) -> None:
        MEETINGS.mkdir(parents=True, exist_ok=True)

    def create(self, title: str) -> dict:
        record = {
            "id": str(uuid.uuid4()), "title": title,
            "startedAt": datetime.now(timezone.utc).isoformat(),
            "endedAt": None, "status": "active", "category": None,
        }
        directory = MEETINGS / record["id"]
        directory.mkdir()
        self._write(directory / "metadata.json", record)
        self._write(directory / "analysis.json", self.empty_analysis())
        return {"record": record, "transcript": [], "analysis": self.empty_analysis(), "questions": []}

    def list(self) -> list[dict]:
        records = []
        for path in MEETINGS.glob("*/metadata.json"):
            try:
                records.append(json.loads(path.read_text("utf-8")))
            except (OSError, json.JSONDecodeError):
                pass
        return sorted(records, key=lambda item: item["startedAt"], reverse=True)

    def load(self, meeting_id: str) -> dict:
        directory = MEETINGS / meeting_id
        transcript_by_id = {}
        for item in self._lines(directory / "transcript.jsonl"):
            transcript_by_id[item["id"]] = item
        return {
            "record": json.loads((directory / "metadata.json").read_text("utf-8")),
            "transcript": sorted(transcript_by_id.values(), key=lambda item: item["startTime"]),
            "analysis": self._read(directory / "analysis.json", self.empty_analysis()),
            "questions": self._lines(directory / "qa.jsonl"),
        }

    def save_record(self, record: dict) -> None:
        self._write(MEETINGS / record["id"] / "metadata.json", record)

    def append_segment(self, meeting_id: str, segment: dict) -> None:
        self._append(MEETINGS / meeting_id / "transcript.jsonl", segment)

    def replace_transcript(self, meeting_id: str, segments: list[dict]) -> None:
        target = MEETINGS / meeting_id / "transcript.jsonl"
        temporary = target.with_suffix(".tmp")
        temporary.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in segments), "utf-8")
        os.replace(temporary, target)

    def save_analysis(self, meeting_id: str, analysis: dict) -> None:
        self._write(MEETINGS / meeting_id / "analysis.json", analysis)

    def append_question(self, meeting_id: str, item: dict) -> None:
        self._append(MEETINGS / meeting_id / "qa.jsonl", item)

    def export_markdown(self, document: dict, destination: str) -> None:
        record, analysis = document["record"], document["analysis"]
        lines = [f"# {record['title']}", "", f"- 开始时间：{record['startedAt']}", "", "## 摘要", "", analysis.get("summary") or "暂无"]
        for title, key in (("决策", "decisions"), ("待办", "actionItems"), ("风险", "risks")):
            lines += ["", f"## {title}", ""]
            values = analysis.get(key) or []
            for value in values:
                lines.append(f"- {value.get('task', '') if isinstance(value, dict) else value}")
            if not values:
                lines.append("- 暂无")
        lines += ["", "## 转写", ""]
        lines += [f"- [{timestamp(s['startTime'])}] {source_name(s['source'])}：{s['text']}" for s in document["transcript"]]
        lines += ["", "## 问答", ""]
        for item in document["questions"]:
            lines += [f"### 问：{item['question']}", "", item.get("answer", ""), ""]
        Path(destination).write_text("\n".join(lines), "utf-8")

    @staticmethod
    def empty_analysis() -> dict:
        return {"summary": "", "decisions": [], "actionItems": [], "risks": [], "updatedAt": None}

    @staticmethod
    def _read(path: Path, default):
        try:
            return json.loads(path.read_text("utf-8"))
        except (OSError, json.JSONDecodeError):
            return default

    @staticmethod
    def _lines(path: Path) -> list[dict]:
        try:
            return [json.loads(line) for line in path.read_text("utf-8").splitlines() if line]
        except OSError:
            return []

    @staticmethod
    def _write(path: Path, value: dict) -> None:
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), "utf-8")
        os.replace(temporary, path)

    @staticmethod
    def _append(path: Path, value: dict) -> None:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(value, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())


def source_name(source: str) -> str:
    return "我" if source == "me" else "其他人"


class APIClient:
    def __init__(self, settings: dict, api_key: str) -> None:
        self.url = settings.get("baseURL", "").rstrip("/") + "/chat/completions"
        self.model = settings.get("model", "")
        self.api_key = api_key

    def chat(self, messages: list[dict], stream: bool = False):
        if not self.url.startswith(("http://", "https://")) or not self.model or not self.api_key:
            raise ValueError("请先配置 API Base URL、模型名和 API Key")
        body = json.dumps({"model": self.model, "messages": messages, "stream": stream}).encode()
        request = urllib.request.Request(self.url, body, {
            "Content-Type": "application/json", "Authorization": f"Bearer {self.api_key}",
        })
        try:
            response = urllib.request.urlopen(request, timeout=90)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"API 请求失败（HTTP {error.code}）：{error.read(1000).decode(errors='replace')}") from error
        if not stream:
            envelope = json.load(response)
            return envelope["choices"][0]["message"]["content"]

        def chunks():
            with response:
                for raw in response:
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        return
                    try:
                        delta = json.loads(payload)["choices"][0]["delta"].get("content")
                        if delta:
                            yield delta
                    except (KeyError, IndexError, json.JSONDecodeError):
                        continue
        return chunks()

    def analyze(self, previous: dict, segments: list[dict]) -> dict:
        transcript = "\n".join(f"[{timestamp(s['startTime'])}] {source_name(s['source'])}：{s['text']}" for s in segments)
        content = self.chat([
            {"role": "system", "content": "根据既有分析和会议转写返回完整 JSON，不得猜测。格式：{\"summary\":\"\",\"decisions\":[],\"actionItems\":[{\"task\":\"\",\"owner\":null,\"due\":null}],\"risks\":[]}"},
            {"role": "user", "content": f"既有分析：{json.dumps(previous, ensure_ascii=False)}\n新增转写：\n{transcript}"},
        ])
        start, end = content.find("{"), content.rfind("}")
        result = json.loads(content[start:end + 1])
        result["updatedAt"] = datetime.now(timezone.utc).isoformat()
        return result

    def refine(self, segments: list[dict]) -> dict[str, str]:
        payload = "\n".join(f"{s['id']} | [{timestamp(s['startTime'])}] {source_name(s['source'])}：{s['text']}" for s in segments)
        content = self.chat([
            {"role": "system", "content": "修正明显错字、断句、专有名词和重复词，不得添加事实或改变说话人。返回 JSON：{\"segments\":[{\"id\":\"UUID\",\"text\":\"校订文字\"}]}"},
            {"role": "user", "content": payload},
        ])
        data = json.loads(content[content.find("{"):content.rfind("}") + 1])
        valid = {item["id"]: item["text"].strip() for item in data.get("segments", []) if item.get("id") and item.get("text", "").strip()}
        return valid


class AudioArchive:
    def __init__(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="MeetingAssistant-"))
        self.files = {}
        self.positions = {"me": 0, "others": 0}
        for source in self.positions:
            path = self.directory / f"{source}.wav"
            handle = wave.open(str(path), "wb")
            handle.setnchannels(1); handle.setsampwidth(2); handle.setframerate(SAMPLE_RATE)
            self.files[source] = handle

    def write(self, source: str, samples, end_time: float) -> None:
        import numpy as np
        pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2")
        target_start = max(0, int(end_time * SAMPLE_RATE) - len(pcm))
        missing = min(max(0, target_start - self.positions[source]), SAMPLE_RATE * 60)
        if missing:
            self.files[source].writeframesraw(b"\0\0" * missing)
        self.files[source].writeframesraw(pcm.tobytes())
        self.positions[source] = target_start + len(pcm)

    def close(self) -> dict[str, Path]:
        for handle in self.files.values():
            handle.close()
        return {source: self.directory / f"{source}.wav" for source in self.positions}

    def remove(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)


class LocalTranscriber:
    def __init__(self, model_name: str, emit) -> None:
        self.model_name, self.emit = model_name, emit
        self.condition = threading.Condition()
        self.finals = collections.deque()
        self.partials = {}
        self.running = True
        self.busy = False
        self.model = None
        threading.Thread(target=self._worker, daemon=True).start()

    def submit(self, source: str, samples, start_time: float, final: bool) -> None:
        with self.condition:
            job = (source, samples.copy(), start_time, final)
            if final:
                self.finals.append(job)
                self.partials.pop(source, None)
            else:
                self.partials[source] = job
            self.condition.notify()

    def finish(self) -> None:
        while True:
            with self.condition:
                if not self.finals and not self.partials and not self.busy:
                    return
            time.sleep(.1)

    def review(self, files: dict[str, Path]) -> list[dict]:
        self._load_model()
        reviewed = []
        for source, path in files.items():
            if path.stat().st_size <= 44:
                continue
            segments, _ = self.model.transcribe(str(path), language="zh", beam_size=3, vad_filter=True)
            for segment in segments:
                text = segment.text.strip()
                if text:
                    reviewed.append(make_segment(source, segment.start, segment.end, text))
        return sorted(reviewed, key=lambda item: item["startTime"])

    def stop(self) -> None:
        with self.condition:
            self.running = False
            self.condition.notify()

    def _load_model(self) -> None:
        if self.model is None:
            self.emit(("status", f"首次使用正在下载并加载本地模型 {self.model_name}…"))
            from faster_whisper import WhisperModel
            self.model = WhisperModel(self.model_name, device="cpu", compute_type="int8")
            self.emit(("status", "本地模型已就绪"))

    def _worker(self) -> None:
        try:
            self._load_model()
            while self.running:
                with self.condition:
                    while self.running and not self.finals and not self.partials:
                        self.condition.wait()
                    if not self.running:
                        return
                    job = self.finals.popleft() if self.finals else min(self.partials.values(), key=lambda value: value[2])
                    if not job[3]:
                        self.partials.pop(job[0], None)
                    self.busy = True
                source, samples, start_time, final = job
                segments, _ = self.model.transcribe(samples, language="zh", beam_size=1, vad_filter=True)
                text = "".join(segment.text for segment in segments).strip()
                if text:
                    self.emit(("transcript", source, start_time, start_time + len(samples) / SAMPLE_RATE, text, final))
                with self.condition:
                    self.busy = False
                    self.condition.notify_all()
        except Exception as error:
            self.emit(("error", f"本地转写失败：{error}"))


def make_segment(source: str, start: float, end: float, text: str) -> dict:
    return {"id": str(uuid.uuid4()), "startTime": max(0, start), "endTime": max(start, end), "source": source, "text": text, "isFinal": True}


class MeetingApp:
    def __init__(self) -> None:
        import tkinter as tk
        from tkinter import ttk
        self.tk, self.ttk = tk, ttk
        self.root = tk.Tk(); self.root.title(APP_NAME); self.root.geometry("1180x760"); self.root.minsize(850, 580)
        self.store = MeetingStore(); self.document = None; self.started = 0.0
        self.active = False; self.mic_enabled = False; self.capture_threads = []
        self.events = queue.Queue(); self.live = {}; self.archive = None; self.transcriber = None
        self.refined_ids = set(); self.api_busy = False
        self.settings = self._load_settings()
        self._build_ui(); self._reload_history(); self.root.after(100, self._poll); self.root.after(30_000, self._api_tick)

    def run(self) -> None:
        self.root.mainloop()

    def _build_ui(self) -> None:
        from tkinter import filedialog
        self.filedialog = filedialog
        toolbar = self.ttk.Frame(self.root, padding=8); toolbar.pack(fill="x")
        self.ttk.Button(toolbar, text="开始新会议", command=self.start_meeting).pack(side="left")
        self.mic_button = self.ttk.Button(toolbar, text="开启麦克风", command=self.toggle_mic, state="disabled"); self.mic_button.pack(side="left", padx=6)
        self.end_button = self.ttk.Button(toolbar, text="结束会议", command=self.end_meeting, state="disabled"); self.end_button.pack(side="left")
        self.ttk.Button(toolbar, text="导出 Markdown", command=self.export).pack(side="left", padx=6)
        self.ttk.Button(toolbar, text="设置", command=self.show_settings).pack(side="right")
        pane = self.ttk.Panedwindow(self.root, orient="horizontal"); pane.pack(fill="both", expand=True)
        left = self.ttk.Frame(pane, padding=8); right = self.ttk.Frame(pane, padding=8); pane.add(left, weight=1); pane.add(right, weight=4)
        self.history = self.ttk.Treeview(left, columns=("time",), show="tree headings"); self.history.heading("#0", text="会议"); self.history.heading("time", text="时间"); self.history.column("time", width=115); self.history.pack(fill="both", expand=True); self.history.bind("<<TreeviewSelect>>", self.select_history)
        notebook = self.ttk.Notebook(right); notebook.pack(fill="both", expand=True)
        transcript_page = self.ttk.Frame(notebook); analysis_page = self.ttk.Frame(notebook); notebook.add(transcript_page, text="实时转写"); notebook.add(analysis_page, text="分析与问答")
        self.transcript = self.tk.Text(transcript_page, wrap="word", font=("Microsoft YaHei UI", 11), padx=14, pady=12); self.transcript.pack(fill="both", expand=True); self.transcript.configure(state="disabled")
        self.analysis = self.tk.Text(analysis_page, wrap="word", height=20, padx=14, pady=12); self.analysis.pack(fill="both", expand=True)
        ask = self.ttk.Frame(analysis_page, padding=(0, 8)); ask.pack(fill="x"); self.question = self.ttk.Entry(ask); self.question.pack(side="left", fill="x", expand=True); self.question.bind("<Return>", lambda _: self.ask()); self.ttk.Button(ask, text="提问", command=self.ask).pack(side="left", padx=(8, 0))
        self.status = self.tk.StringVar(value="就绪"); self.ttk.Label(self.root, textvariable=self.status, padding=6).pack(fill="x")

    def start_meeting(self) -> None:
        from tkinter import simpledialog, messagebox
        if self.active:
            return
        title = simpledialog.askstring("开始新会议", "会议名称：", initialvalue=datetime.now().strftime("会议 %Y-%m-%d %H:%M"), parent=self.root)
        if title is None:
            return
        try:
            self.document = self.store.create(title.strip() or "未命名会议")
            self.started = time.monotonic(); self.active = True; self.archive = AudioArchive()
            self.transcriber = LocalTranscriber(self.settings.get("whisperModel", "small"), self.events.put)
            self.capture_threads = [threading.Thread(target=self._capture, args=("others",), daemon=True), threading.Thread(target=self._capture, args=("me",), daemon=True)]
            for thread in self.capture_threads: thread.start()
            self.mic_button.configure(state="normal"); self.end_button.configure(state="normal"); self._reload_history(); self._render()
        except Exception as error:
            self.active = False; messagebox.showerror(APP_NAME, str(error))

    def _capture(self, source: str) -> None:
        try:
            import numpy as np
            import soundcard as sc
            if source == "others":
                speaker = sc.default_speaker()
                devices = [item for item in sc.all_microphones(include_loopback=True) if getattr(item, "isloopback", False)]
                device = next((item for item in devices if speaker.name.lower() in item.name.lower()), devices[0] if devices else None)
                if device is None: raise RuntimeError("没有找到 WASAPI 系统音频回环设备")
            else:
                device = sc.default_microphone()
                if device is None: raise RuntimeError("没有找到默认麦克风")
            utterance = np.empty(0, dtype=np.float32); utterance_start = 0.0; silence = 0; since_decode = 0
            with device.recorder(samplerate=SAMPLE_RATE, channels=1) as recorder:
                while self.active:
                    if source == "me" and not self.mic_enabled:
                        time.sleep(.1); continue
                    chunk = np.asarray(recorder.record(numframes=SAMPLE_RATE // 2), dtype=np.float32).reshape(-1)
                    end_time = time.monotonic() - self.started; self.archive.write(source, chunk, end_time)
                    voice = math.sqrt(float(np.mean(chunk * chunk))) >= .006
                    if len(utterance) == 0:
                        if not voice: continue
                        utterance_start = max(0, end_time - len(chunk) / SAMPLE_RATE)
                    utterance = np.concatenate((utterance, chunk)); since_decode += len(chunk); silence = 0 if voice else silence + len(chunk)
                    final = silence >= int(.8 * SAMPLE_RATE) or len(utterance) >= 15 * SAMPLE_RATE
                    if final:
                        self.transcriber.submit(source, utterance, utterance_start, True); utterance = np.empty(0, dtype=np.float32); silence = since_decode = 0
                    elif since_decode >= 2 * SAMPLE_RATE:
                        self.transcriber.submit(source, utterance[-10 * SAMPLE_RATE:], max(utterance_start, end_time - 10), False); since_decode = 0
                if len(utterance): self.transcriber.submit(source, utterance, utterance_start, True)
        except Exception as error:
            self.events.put(("error", f"{source_name(source)}音频采集失败：{error}"))

    def toggle_mic(self) -> None:
        self.mic_enabled = not self.mic_enabled
        self.mic_button.configure(text="关闭麦克风" if self.mic_enabled else "开启麦克风")

    def end_meeting(self) -> None:
        if not self.active: return
        self.active = False; self.mic_enabled = False; self.mic_button.configure(state="disabled"); self.end_button.configure(state="disabled"); self.status.set("正在完成转写与全程复核…")
        threading.Thread(target=self._finalize, daemon=True).start()

    def _finalize(self) -> None:
        for thread in self.capture_threads: thread.join(timeout=3)
        self.transcriber.finish(); files = self.archive.close()
        try:
            reviewed = self.transcriber.review(files)
            if reviewed: self.events.put(("review", reviewed))
        except Exception as error:
            self.events.put(("error", f"全程复核失败，已保留实时转写：{error}"))
        finally:
            self.archive.remove(); self.transcriber.stop()
        self.events.put(("finished",))

    def _poll(self) -> None:
        from tkinter import messagebox
        try:
            while True:
                event = self.events.get_nowait(); kind = event[0]
                if kind == "status": self.status.set(event[1])
                elif kind == "error": messagebox.showerror(APP_NAME, event[1])
                elif kind == "transcript": self._accept_transcript(*event[1:])
                elif kind == "review":
                    self.document["transcript"] = event[1]; self.store.replace_transcript(self.document["record"]["id"], event[1]); self._render()
                elif kind == "finished":
                    record = self.document["record"]; record["status"] = "finished"; record["endedAt"] = datetime.now(timezone.utc).isoformat(); self.store.save_record(record); self.status.set("会议已结束"); self._reload_history(); self._run_api(final=True)
                elif kind == "analysis": self.document["analysis"] = event[1]; self.store.save_analysis(self.document["record"]["id"], event[1]); self._render(); self.api_busy = False
                elif kind == "question": self._append_answer(event[1])
        except queue.Empty:
            pass
        self.root.after(100, self._poll)

    def _accept_transcript(self, source: str, start: float, end: float, text: str, final: bool) -> None:
        if not self.document: return
        if not final: self.live[source] = (start, text); self._render(); return
        previous = next((item["text"] for item in reversed(self.document["transcript"]) if item["source"] == source), "")
        text = remove_overlap(previous, text); self.live.pop(source, None)
        if not text: return
        segment = make_segment(source, start, end, text); self.document["transcript"].append(segment); self.document["transcript"].sort(key=lambda item: item["startTime"]); self.store.append_segment(self.document["record"]["id"], segment); self._render()

    def _api_tick(self) -> None:
        if self.active: self._run_api()
        self.root.after(30_000, self._api_tick)

    def _run_api(self, final: bool = False) -> None:
        if self.api_busy or not self.document or not self.document["transcript"] or not self._api_key(): return
        self.api_busy = True
        def work():
            try:
                client = APIClient(self.settings, self._api_key())
                targets = self.document["transcript"] if final else [s for s in self.document["transcript"] if s["id"] not in self.refined_ids][-20:]
                if targets:
                    revisions = client.refine(targets)
                    for segment in self.document["transcript"]:
                        if segment["id"] in revisions: segment["text"] = revisions[segment["id"]]
                    self.refined_ids.update(s["id"] for s in targets); self.store.replace_transcript(self.document["record"]["id"], self.document["transcript"])
                analysis = client.analyze(self.document["analysis"], targets or self.document["transcript"])
                self.events.put(("analysis", analysis))
            except Exception as error:
                self.api_busy = False; self.events.put(("error", f"API 分析失败，本地转写继续：{error}"))
        threading.Thread(target=work, daemon=True).start()

    def ask(self) -> None:
        question = self.question.get().strip()
        if not question or not self.document: return
        self.question.delete(0, "end")
        item = {"id": str(uuid.uuid4()), "question": question, "answer": "", "createdAt": datetime.now(timezone.utc).isoformat(), "status": "streaming"}; self.document["questions"].append(item); self._render()
        def work():
            try:
                context = "\n".join(f"[{timestamp(s['startTime'])}] {source_name(s['source'])}：{s['text']}" for s in self.document["transcript"][-100:])
                client = APIClient(self.settings, self._api_key())
                for chunk in client.chat([{"role": "system", "content": f"只能依据会议记录回答，依据不足时明确说明。\n{context}"}, {"role": "user", "content": question}], stream=True):
                    self.events.put(("question", (item["id"], chunk, False)))
                self.events.put(("question", (item["id"], "", True)))
            except Exception as error: self.events.put(("question", (item["id"], f"请求失败：{error}", True)))
        threading.Thread(target=work, daemon=True).start()

    def _append_answer(self, update) -> None:
        item_id, chunk, done = update
        item = next((value for value in self.document["questions"] if value["id"] == item_id), None)
        if not item: return
        item["answer"] += chunk; item["status"] = "completed" if done else "streaming"; self._render()
        if done: self.store.append_question(self.document["record"]["id"], item)

    def _render(self) -> None:
        if not self.document: return
        entries = [(s["startTime"], f"[{timestamp(s['startTime'])}] {source_name(s['source'])}：{s['text']}") for s in self.document["transcript"]]
        entries += [(value[0], f"[{timestamp(value[0])}] {source_name(source)}：{value[1]}  …") for source, value in self.live.items()]
        self.transcript.configure(state="normal"); self.transcript.delete("1.0", "end"); self.transcript.insert("end", "\n\n".join(text for _, text in sorted(entries))); self.transcript.configure(state="disabled"); self.transcript.see("end")
        analysis = self.document["analysis"]; text = f"摘要\n{analysis.get('summary') or '暂无'}\n\n决策\n" + "\n".join(f"• {x}" for x in analysis.get("decisions", [])) + "\n\n待办\n" + "\n".join(f"• {x.get('task')}" for x in analysis.get("actionItems", [])) + "\n\n风险\n" + "\n".join(f"• {x}" for x in analysis.get("risks", []))
        for item in self.document["questions"]: text += f"\n\n问：{item['question']}\n答：{item['answer'] or '正在回答…'}"
        self.analysis.delete("1.0", "end"); self.analysis.insert("end", text)

    def _reload_history(self) -> None:
        for item in self.history.get_children(): self.history.delete(item)
        for record in self.store.list(): self.history.insert("", "end", iid=record["id"], text=record["title"], values=(record["startedAt"][:16].replace("T", " "),))

    def select_history(self, _event=None) -> None:
        selection = self.history.selection()
        if selection and not self.active: self.document = self.store.load(selection[0]); self.live = {}; self._render()

    def export(self) -> None:
        if not self.document: return
        path = self.filedialog.asksaveasfilename(defaultextension=".md", initialfile=safe_filename(self.document["record"]["title"]) + ".md", filetypes=[("Markdown", "*.md")])
        if path: self.store.export_markdown(self.document, path); self.status.set(f"已导出：{path}")

    def show_settings(self) -> None:
        window = self.tk.Toplevel(self.root); window.title("设置"); window.resizable(False, False); frame = self.ttk.Frame(window, padding=14); frame.pack()
        values = {}
        for row, (key, label, default) in enumerate((("baseURL", "API Base URL", "https://api.openai.com/v1"), ("model", "API 模型", ""), ("whisperModel", "本地 Whisper 模型", "small"), ("apiKey", "API Key", self._api_key()))):
            self.ttk.Label(frame, text=label).grid(row=row, column=0, sticky="w", pady=4); entry = self.ttk.Entry(frame, width=48, show="*" if key == "apiKey" else ""); entry.insert(0, self.settings.get(key, default) if key != "apiKey" else default); entry.grid(row=row, column=1, pady=4); values[key] = entry
        def save():
            self.settings = {key: entry.get().strip() for key, entry in values.items() if key != "apiKey"}; SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True); SETTINGS_FILE.write_text(json.dumps(self.settings, ensure_ascii=False, indent=2), "utf-8")
            import keyring
            keyring.set_password(APP_NAME, "api-key", values["apiKey"].get().strip()); window.destroy(); self.status.set("设置已保存")
        self.ttk.Button(frame, text="保存", command=save).grid(row=5, column=1, sticky="e", pady=(10, 0))

    def _load_settings(self) -> dict:
        try: return json.loads(SETTINGS_FILE.read_text("utf-8"))
        except (OSError, json.JSONDecodeError): return {"baseURL": "https://api.openai.com/v1", "model": "", "whisperModel": "small"}

    @staticmethod
    def _api_key() -> str:
        try:
            import keyring
            return keyring.get_password(APP_NAME, "api-key") or ""
        except Exception:
            return ""


def self_check() -> None:
    assert timestamp(3661) == "01:01:01"
    assert remove_overlap("今天讨论发布", "讨论发布计划") == "计划"
    assert remove_overlap("hello", "hello") == ""
    root = Path(tempfile.mkdtemp())
    global ROOT, MEETINGS, SETTINGS_FILE
    original = ROOT, MEETINGS, SETTINGS_FILE
    ROOT, MEETINGS, SETTINGS_FILE = root, root / "Meetings", root / "settings.json"
    try:
        store = MeetingStore(); document = store.create("测试")
        segment = make_segment("others", 0, 2, "测试转写"); store.append_segment(document["record"]["id"], segment)
        assert store.load(document["record"]["id"])["transcript"] == [segment]
    finally:
        ROOT, MEETINGS, SETTINGS_FILE = original; shutil.rmtree(root)
    print("Windows MeetingAssistant checks passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--self-check", action="store_true"); arguments = parser.parse_args()
    if arguments.self_check: self_check()
    else: MeetingApp().run()

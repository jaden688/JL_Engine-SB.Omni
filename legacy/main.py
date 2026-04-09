import os
import asyncio
import base64
import io
import traceback
import cv2
import pyaudio
import PIL.Image
import argparse
import json
import subprocess
from google import genai
from google.genai import types

FORMAT = pyaudio.paInt16
CHANNELS = 1
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000
CHUNK_SIZE = 1024
MODEL = "gemini-2.0-flash-exp"

client = genai.Client(
    http_options={"api_version": "v1beta"},
    api_key=os.environ.get("GEMINI_API_KEY"),
)

# --- Tool Implementations ---
async def read_file(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"Error reading file: {str(e)}"

async def write_file(path: str, content: str) -> str:
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return f"Successfully wrote to {path}"
    except Exception as e:
        return f"Error writing file: {str(e)}"

async def list_files(path: str = ".") -> str:
    try:
        files = os.listdir(path)
        return "\n".join(files)
    except Exception as e:
        return f"Error listing files: {str(e)}"

async def run_command(command: str) -> str:
    try:
        process = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        return f"STDOUT: {stdout.decode()}\nSTDERR: {stderr.decode()}"
    except Exception as e:
        return f"Error executing command: {str(e)}"

# Mapping for the execution loop
TOOL_MAP = {
    "read_file": read_file,
    "write_file": write_file,
    "list_files": list_files,
    "run_command": run_command,
}

# --- Tool Declarations ---
tools = [
    types.Tool(
        function_declarations=[
            types.FunctionDeclaration(
                name="read_file",
                description="Read a file's content from the local filesystem.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "path": types.Schema(type="STRING", description="The path to the file.")
                    },
                    required=["path"],
                ),
            ),
            types.FunctionDeclaration(
                name="write_file",
                description="Write content to a file on the local filesystem.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "path": types.Schema(type="STRING", description="The path to the file."),
                        "content": types.Schema(type="STRING", description="The content to write.")
                    },
                    required=["path", "content"],
                ),
            ),
            types.FunctionDeclaration(
                name="list_files",
                description="List files in a directory.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "path": types.Schema(type="STRING", description="The directory path (defaults to current).")
                    },
                ),
            ),
            types.FunctionDeclaration(
                name="run_command",
                description="Run a shell command on the local system.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "command": types.Schema(type="STRING", description="The shell command to execute.")
                    },
                    required=["command"],
                ),
            ),
        ]
    )
]

with open("sparkbyte.json", "r", encoding="utf-8") as f:
    sparkbyte_config = f.read()

CONFIG = types.LiveConnectConfig(
    response_modalities=["AUDIO"],
    tools=tools,
    speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Zephyr")
        )
    ),
    system_instruction=types.Content(
        parts=[types.Part.from_text(text=sparkbyte_config)],
    ),
)

pya = pyaudio.PyAudio()

class AudioLoop:
    def __init__(self, video_mode="camera"):
        self.video_mode = video_mode
        self.audio_in_queue = None
        self.out_queue = None
        self.session = None
        self.audio_stream = None

    async def send_text(self):
        while True:
            text = await asyncio.to_thread(input, "message > ")
            if text.lower() == "q": break
            if self.session is not None:
                await self.session.send(input=text or ".", end_of_turn=True)

    def _get_frame(self, cap):
        ret, frame = cap.read()
        if not ret: return None
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        img = PIL.Image.fromarray(frame_rgb)
        img.thumbnail([1024, 1024])
        image_io = io.BytesIO()
        img.save(image_io, format="jpeg")
        image_io.seek(0)
        return {"mime_type": "image/jpeg", "data": base64.b64encode(image_io.read()).decode()}

    async def get_frames(self):
        cap = await asyncio.to_thread(cv2.VideoCapture, 0)
        while True:
            frame = await asyncio.to_thread(self._get_frame, cap)
            if frame is None: break
            await asyncio.sleep(1.0)
            if self.out_queue is not None: await self.out_queue.put(frame)
        cap.release()

    async def send_realtime(self):
        while True:
            if self.out_queue is not None:
                msg = await self.out_queue.get()
                if self.session is not None: await self.session.send(input=msg)

    async def listen_audio(self):
        self.audio_stream = await asyncio.to_thread(pya.open, format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE, input=True, frames_per_buffer=CHUNK_SIZE)
        while True:
            data = await asyncio.to_thread(self.audio_stream.read, CHUNK_SIZE, exception_on_overflow=False)
            if self.out_queue is not None: await self.out_queue.put({"data": data, "mime_type": "audio/pcm"})

    async def receive_audio(self):
        while True:
            if self.session is not None:
                async for response in self.session.receive():
                    if data := response.data: self.audio_in_queue.put_nowait(data)
                    if text := response.text: print(text, end="")
                    
                    if tool_calls := response.tool_call:
                        for call in tool_calls.function_calls:
                            print(f"\n[SparkByte is using {call.name} with args {call.args}]")
                            func = TOOL_MAP.get(call.name)
                            if func:
                                result = await func(**call.args)
                                await self.session.send(
                                    input=types.LiveClientToolResponse(
                                        function_responses=[
                                            types.FunctionResponse(
                                                name=call.name,
                                                id=call.id,
                                                response={"result": result}
                                            )
                                        ]
                                    )
                                )
                while not self.audio_in_queue.empty(): self.audio_in_queue.get_nowait()

    async def play_audio(self):
        stream = await asyncio.to_thread(pya.open, format=FORMAT, channels=CHANNELS, rate=RECEIVE_SAMPLE_RATE, output=True)
        while True:
            if self.audio_in_queue is not None:
                bytestream = await self.audio_in_queue.get()
                await asyncio.to_thread(stream.write, bytestream)

    async def run(self):
        try:
            async with (
                client.aio.live.connect(model=MODEL, config=CONFIG) as session,
                asyncio.TaskGroup() as tg,
            ):
                self.session = session
                self.audio_in_queue = asyncio.Queue()
                self.out_queue = asyncio.Queue(maxsize=5)
                tg.create_task(self.send_text())
                tg.create_task(self.send_realtime())
                tg.create_task(self.listen_audio())
                if self.video_mode == "camera": tg.create_task(self.get_frames())
                tg.create_task(self.receive_audio())
                tg.create_task(self.play_audio())
                await asyncio.Future() # Keep alive
        except Exception:
            if self.audio_stream: self.audio_stream.close()
            traceback.print_exc()

if __name__ == "__main__":
    main = AudioLoop(video_mode="camera")
    asyncio.run(main.run())

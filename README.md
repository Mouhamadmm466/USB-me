# TokeIT

A private voice assistant that runs on your iPhone.

You talk to it. It understands you, does the task, and tells you what it did. Your voice never
leaves the phone. There is no account, no server, and no internet needed for most of what it does.

Website: [tokeit.dev](https://tokeit.dev)

## What makes it different

Most voice assistants send your words to a company's servers. This one does not. The speech
recognition, the language model, and the voice all run on the phone itself.

But being private is not the whole idea. The bigger idea is this:

> **It builds a model of your world, and that model belongs to you.**

It remembers your projects, the people in them, what you promised, and what is due. It can read the
documents you give it. It can reach your calendar, your email, and your files when you allow it. And
you can open the whole thing, see where every single fact came from, change it, or delete it.

## Three things you should try first

**1. Ask it to do something.**

> "Text Alex that I will be 20 minutes late."

It finds Alex in your contacts, writes the message, and shows it to you. Nothing is sent until you
say yes.

**2. Tell it about your life, then ask later.**

> Monday: "I am building Guard with Sarah."
> Tuesday: "We decided to keep Nemotron."
> Friday: "What is still open on Guard?"

It answers from what you told it. You never have to explain Guard twice.

**3. Give it a job, not a command.**

> "Look up the new benchmarks and write me a short report."

It shows you a plan first. You approve it. Then it does the steps and writes the report, which you
can read and keep.

## Where to go next

Start here if you want to understand the project:

* [What it is and why](docs/overview.md)
* [What you can actually do with it](docs/use_cases.md)
* [How it works inside](docs/how_it_works.md)

Then, for detail:

* [The memory, and how it stays honest](docs/memory.md)
* [Connecting Gmail, Drive and GitHub](docs/connected_services.md)
* [Privacy and safety](docs/privacy.md)
* [Testing and results](docs/evaluation/README.md)
* [How to build and run it](docs/setup/README.md)
* [What it still cannot do](docs/limitations.md)

There is also an [interactive page](docs/index.html). Open it in a browser for a visual tour.

## What is inside the repository

The code is split into small Swift packages. Each one does one job.

**The brain and the voice**

* `LLM` runs the language model and forces its output into a shape we can check
* `ASR` turns speech into text
* `TTS` turns text into speech
* `Audio` handles the microphone, the speaker, and talking over the assistant

**The thinking**

* `Agent` runs the conversation and the multi step jobs
* `Intelligence` is the memory: people, projects, promises, documents
* `Connectors` talks to Gmail, Drive and GitHub

**The doing**

* `Tools` reaches the phone: contacts, calendar, reminders, messages, calls, files
* `Permissions` asks for access at the right moment
* `Storage` saves settings and history
* `Models` downloads and verifies the model files

**The app**

* `App` is the iPhone app itself, the screens and the share extension

**The proof**

* `Tests` holds every automated test and the evaluation harness
* `docs` holds this documentation

## A note on how this was built

This project was built with an AI coding assistant as a working partner. The design decisions, the
rules about safety and privacy, and the direction all came from real choices made along the way, and
many of them were changed after testing showed the first idea was wrong.

Where something did not work, the documentation says so. You will find a list of real bugs we found
and fixed in [docs/notes/status.md](docs/notes/status.md), including a few that only showed up when
we ran the real model on a real phone.

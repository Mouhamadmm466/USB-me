# What this is, and why we built it

## The short version

TokeIT is a voice assistant that lives entirely on your iPhone. You talk, it understands, it acts.
Your voice and your words never go to a server.

On top of that, it keeps a model of your world: your projects, the people in them, what you
promised, what is due. That model is a file on your phone. You can read it, correct it, export it,
or delete it.

## The problem

Today you have two kinds of assistant, and both of them have a hole in the middle.

**The ones that know things about you** run in the cloud. ChatGPT and similar tools can remember
you, but that memory sits on a company's computer. It has no structure, it cannot tell you where a
fact came from, and you cannot really correct it. You can only delete it and start again.

**The ones that run on your phone** do not really know you. Siri and Apple Intelligence are on your
device and are private, but they have no lasting picture of your life. Every request starts from
nothing. Ask about a project you have been working on for a month and it has never heard of it.

So you either get privacy without memory, or memory without privacy.

## What we are trying to do

Fill the hole. A model of your life that:

1. **builds itself** from things you allow, like your own words, your calendar, and documents you
   share with it
2. **can explain itself**, so every fact can say where it came from and when
3. **can be corrected**, because you are always right and it is not
4. **belongs to you**, as one file you can take with you
5. **acts inside limits you set**, and asks before anything that matters

The assistant you talk to is just a window onto that model. The model is the product.

## Why on the phone

Running everything on the device is not only about privacy, although privacy is a big part of it.

It also means the assistant works on a plane, in a basement, and in a country where your data would
otherwise cross a border. There is no account to make, no subscription, and no company that can read
your notes, change the rules, or shut the service down.

The cost is real. A phone cannot run a huge model. We measured that cost carefully. See
[the model comparison](evaluation/model_comparison/README.md).

## The rule that shapes everything

There is one rule underneath the whole design:

> **The model proposes. The app decides.**

The language model never sends a message, never writes to the database, never touches the internet,
and never calls anyone. It only suggests. Swift code then checks the suggestion, looks up the real
person or event itself, reads back exactly what it is about to do, and waits for you.

This is why a small model is enough. The model does the part it is good at, which is understanding
language. It does not do the part it is bad at, which is being careful.

It is also why a mistake is not dangerous. If the model gets confused, the worst it can do is
suggest something wrong, which you then see and refuse.

## What it can do today

* Understand what you say and act on it: messages, calls, calendar, reminders, files, apps
* Remember your world over days and weeks, and answer questions about it
* Read documents you share with it, and answer from them, saying which page
* Take on a job that needs several steps, show you the plan, then do it
* Look things up on the internet when you allow it, and show you exactly what left the phone
* Reach your Gmail, Google Drive and GitHub when you connect them
* Work fully offline for everything above except the last two

## What it cannot do yet

We keep an honest list in [limitations](limitations.md). The short version: the thinking step is
slower than we wanted on the phone, the voice test on a real device has not been finished, and the
connected services have never been tested against a live account.

## The name

TokeIT. The website is at [tokeit.dev](https://tokeit.dev).

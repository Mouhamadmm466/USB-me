# What you can do with it

Real examples, in the order a new user would meet them.

## 1. Simple commands

This is the part every voice assistant claims. The difference here is what happens before it acts.

> **You:** "Text Alex that I will be 20 minutes late."
>
> **It:** "Text Alex Kim: I will be 20 minutes late. Should I send it?"
>
> **You:** "Yes."
>
> **It:** Messages opens with the text ready. You tap send.

Notice three things. It found the real Alex in your contacts, not a guess. It read back the exact
message. And it did not send anything until you said yes.

Other things in this group:

* "What is on my calendar tomorrow?"
* "Remind me to pay rent on the first at 9am."
* "Put lunch with Priya on Friday at noon."
* "Call mom."
* "Open the floor plan."

## 2. It learns your world as you talk

You do not fill in a form. You just talk normally over days.

> **Monday:** "I am building Guard with Sarah."
> **Monday:** "Sarah is doing the interface."
> **Tuesday:** "We decided to keep Nemotron 3 Nano."
> **Wednesday:** "I told Sarah I would finish the benchmark tomorrow."
> **Wednesday:** "The demo needs to be ready Friday."

Those five sentences become connected information: a project, a person with a role, a decision, a
promise with a date, and a deadline.

Then, days later:

> **You:** "What is still open on Guard?"
>
> **It:** Answers from what you told it. You never explain Guard again.

You can also ask it to show its work:

> **You:** "Why do you think the demo is Friday?"
>
> **It:** "You told me on Wednesday."

## 3. You can correct it, and correction wins

> **You:** "Actually Sarah is not on Guard anymore."

The old fact is not deleted. It is marked as ended, with the date. The new fact takes over. If you
ever ask what changed, the history is there.

The rule is that your own words beat anything else. If your calendar says one thing and you said
another, you win. The calendar's version stays visible as the thing that disagreed.

## 4. Documents

Share a PDF, a Word file, a web page or a note to the app from anywhere on the phone. Use the normal
iOS share sheet.

> **You:** Share a syllabus, then ask "What does the syllabus say about the midterm?"
>
> **It:** Answers, and tells you which page it read it on.

You can also point it at a folder of files and let it search inside.

## 5. Jobs, not just commands

Some things take more than one step. For those, it makes a plan and shows you the plan first.

> **You:** "What does the syllabus say about the midterm, and make me a study plan."
>
> **It:** "Midterm study plan, in two steps. Want me to go ahead?"
>
> You see the steps: find what the midterm covers, then write the plan.
>
> **You:** "Go ahead."
>
> **It:** Does both steps and writes a plan you can read and keep.

Approving the plan is the approval. But anything with a real consequence, like sending a message,
stops and asks again at the moment it would happen.

## 6. Looking things up

When the internet is allowed, it can go and find things.

> **You:** "Look up what Nemotron is."
>
> **It:** Shows you a plan with one step. You approve it. It searches and tells you what it found.

You control this with one setting that has three positions: never, ask every time, or allow inside
jobs you already approved.

Every single request that leaves the phone is written down, including the ones that were refused.
You can read that list in the settings under "What left this iPhone". It shows the exact words that
were sent, where they went, and why.

There is also a rule that stops your private information going out by accident. If the app knows a
project called Guard, it will not put the word Guard into a web search unless you said it yourself
in your request.

## 7. Your email, your files, your code

When you connect Gmail, Google Drive or GitHub, they become things the assistant can use in the
same way as everything else.

> **You:** "I got an email from Laverana last week and I do not think she followed up. Check, and
> send her a follow up if she did not."

That one sentence needs four things: find the email, see if there was a reply, write a follow up,
and send it. It makes a plan, does the searching, shows you the message it wants to send, and waits.

Other examples:

* "What did Sarah send me about the demo?"
* "Do I have any emails I need to respond to?"
* "Find the file about the architecture in my Drive."
* "Open an issue for this in the repo."

You decide what each service may do, one ability at a time. Reading your email and sending email as
you are two separate switches. Reading starts on. Sending starts at "ask every time". Anything set
to off is not even offered to the model, so it cannot ask for something you turned off.

## 8. Asking what matters

> **You:** "What needs my attention?"

It answers using rules, not guesses: things that are late first, then things due today, then
deadlines with nothing done yet, then promises with no date, then questions it is holding for you.

Every item comes with the reason, like "you promised Sarah, no date on it".

## 9. Press and hold the Action button

On an iPhone with an Action button, you can set it to open the app already listening. No tapping.
You press, you talk.

## A full example, end to end

This is the one that shows the whole idea working together.

> **You:** "I am meeting Sarah tomorrow. Work out what we need to talk about and get everything
> ready."

What it does:

1. Looks up who Sarah is in your world
2. Finds tomorrow's meeting in your calendar
3. Finds the project you share
4. Finds the goal and the open work on it
5. Finds what you promised her
6. Searches your email for recent messages from her
7. Finds the related document
8. Writes a meeting brief and saves it

Then it says something like: "You are meeting Sarah tomorrow at 2. The main things are the benchmark
you promised her, the remaining device tests, and Monday's demo. I made you a brief."

You never said search my calendar, or search my email, or search my notes. You said what you wanted.

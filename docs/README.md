# Documentation

Start with the [main README](../README.md), then come here for detail.

## Read in this order

1. [Overview](overview.md) what it is, the problem it solves, and the one rule underneath it
2. [Use cases](use_cases.md) what you can actually do, with real examples
3. [How it works](how_it_works.md) the pipeline, the memory, the safety model

Or open [index.html](index.html) in a browser for a visual tour.

## Detail

* [The memory](memory.md) how facts are stored, ranked and corrected
* [Connected services](connected_services.md) Gmail, Drive and GitHub
* [Privacy](privacy.md) what stays on the phone, and what does not
* [Limitations](limitations.md) what it still cannot do

## Evidence

* [Testing and results](evaluation/README.md) all four kinds of testing
* [Model comparison](evaluation/model_comparison/README.md) why Nemotron 4B was chosen
* [Device measurements](evaluation/device_results.md) speed and memory on a real iPhone
* [Agent tests](evaluation/agent_tests.md) the 3,249 case command dataset

## Running it yourself

* [Build and run](setup/README.md)
* [Dependencies](setup/dependencies.md)
* [Model files and checksums](setup/models.md)

## Engineering notes

These are working notes kept during the build. They are rougher than the documents above, and they
are here because they show the real path the project took.

* [Status](notes/status.md) what is built, what is not, and the bugs found along the way
* [Product direction](notes/direction.md) an honest assessment of where the project stands
* [Architecture detail](notes/architecture_detail.md)
* [Security review](notes/security_review.md)
* [Demo script](notes/demo_script.md)
* [The version 2 plan](notes/v2_plan.md)

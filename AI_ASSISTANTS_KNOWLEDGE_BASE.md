# AI Assistants Knowledge Base
*Apple Siri · Google Gemini · OpenAI ChatGPT · Anthropic Claude · others*

**Snapshot date:** 27 October 2026
**Confidence key:** ✅ confirmed by an official or major source · ⚠️ only secondary or blog reporting, so check before relying on it

> This space changes almost every week. Treat model names, prices and user counts as true on the snapshot date only. Sources are listed at the end.

---

## 1. Quick comparison

| | **Siri (Apple)** | **Gemini (Google)** | **ChatGPT (OpenAI)** | **Claude (Anthropic)** |
|---|---|---|---|---|
| Type | OS-level voice/agent assistant | Assistant + model family | Assistant + model family | Assistant + model family |
| Flagship engine (Oct 2026) | Apple Foundation Models (built with Gemini tech) | **Gemini 4 Argon** | **GPT-6 Astra** / GPT-6.1 Sol | **Fable 5.1** / **Opus 5.5** |
| Scale | ~1.5B+ active Apple devices (Siri AI needs iPhone 15 Pro+) | 1B+ monthly app users (Aug 2026) ✅ | ~900M–1B weekly users ⚠️ | Smaller consumer base; strong in enterprise and coding |
| Main strengths | Personal context, on-screen awareness, privacy, deep OS integration | Google ecosystem (Search, Android, Workspace), multimodal, long context | Biggest consumer reach, broadest features (voice, images, Sora video, agents) | Coding (Claude Code), agentic work, long documents, safety |
| Paid tier | Free with device (full Siri AI reportedly needs iCloud+ ⚠️) | Google AI Plus / Pro / Ultra | Go $8 · Plus · Pro $100/$200 · Pro 500 $500 | Pro · Max · Team · Enterprise |
| Developer API | No general LLM API (App Intents, Foundation Models framework on-device) | Gemini API, AI Studio, Vertex / Gemini Enterprise | OpenAI API, Agents API, Codex | Claude API, Bedrock, Vertex, Azure, Claude Code, Agent SDK |

---

## 2. Apple Siri

### History
- **2011:** Launched on the iPhone 4S (Apple bought Siri Inc. in 2010).
- **2016–2023:** Gradual expansion (Mac, HomePod, Shortcuts) but widely seen as behind the competition.
- **June 2024 (WWDC):** **Apple Intelligence** announced, including a "new Siri" with personal context and on-screen awareness, plus an optional **ChatGPT** hand-off.
- **2025:** The personal-Siri features were publicly **delayed**. Apple reorganised its AI leadership.
- **Jan 2026:** Apple and Google signed a **multi-year deal**: Gemini technology powers parts of Apple Intelligence and the next Siri. ✅
- **Feb–Spr 2026:** A partial Siri upgrade was planned for iOS 26.4. Bloomberg reported testing problems, and some features slipped to 26.5 / iOS 27.
- **June 2026 (WWDC):** The rebuilt **"Siri AI"** was unveiled.
- **14 Sep 2026:** **iOS 27 shipped** with Siri AI. ✅

### Siri AI in iOS 27 (current)
- Natural **back-and-forth conversation** and **multiple tasks in one request**.
- **Personal context:** searches Mail, Messages, Notes, Reminders, Calendar, Photos and Files.
- **On-screen awareness + in-app actions** (e.g., drafting an email, adding an event) through App Intents.
- **Standalone Siri app** with conversation history synced across devices. Type or speak.
- **Write with Siri** gives system-wide writing help. **Siri Mode in the Camera** handles Visual Intelligence, which used to hand complex questions to ChatGPT and now no longer needs to.
- Web search for general questions.

### Technology & privacy
- Runs on **Apple Foundation Models**, which Apple built with technology from **Google Gemini**. One outlet reports that complex queries go to a custom, Apple-tuned Gemini variant ⚠️.
- Processing happens **on-device + Private Cloud Compute (PCC)**. Apple says neither Apple nor third parties can access the data. PCC is being expanded onto **Google Cloud with NVIDIA hardware**.
- Third-party "Extensions" letting users pick ChatGPT, Claude or Gemini for some features have been reported but may not be at launch ⚠️.

### Requirements & limits
- iOS 27 supports **iPhone 11 and later**. **Siri AI / Apple Intelligence needs an iPhone 15 Pro or later.** The custom Siri voice and better on-device dictation need an iPhone 17 Pro or iPhone Air.
- **English only** at launch. **Not initially available in the EU or China.**

---

## 3. Google Gemini

### History
- **Dec 2023:** Gemini 1.0 (Ultra/Pro/Nano) launched, replacing PaLM. **Bard** was renamed **Gemini** in Feb 2024.
- **2024:** Gemini 1.5 (1M-token context), then Gemini 2.0 (agentic era) in December.
- **2025:** Gemini 2.5 Pro/Flash (thinking models), then Gemini 3 late in the year. Gemini replaced Google Assistant on Android.
- **May 2026 (I/O):** **Gemini 3.5 Flash** launched. Gemini 3.5 Pro was previewed but its release kept slipping ⚠️.
- **Jul–Aug 2026:** Gemini 3.6 Flash, 3.5 Flash-Lite, Flash Cyber and **Gemini 3.7 Flash** released.
- **Aug 2026:** The Gemini app passed **1 billion monthly users** ✅. It was ~950M at Q2 earnings and ~750M in Feb 2026.
- **30 Sep 2026:** **Gemini 4 Argon** announced, first for vetted cyber defenders (Fairwind program). ✅
- **13 Oct 2026:** **Gemini 4 Argon generally available.** ✅

### Gemini 4 Argon (current flagship)
- Model ID **`gemini-4-argon`**. Built for coding, research and cybersecurity.
- **API price (introductory):** $2 / $10 per 1M input/output tokens.
- **Access:** API (AI Studio, Gemini Enterprise Agent Platform). Gemini app for **Pro and Ultra** subscribers. **Antigravity** (Google's agentic IDE) for Ultra. Not on Free or AI Plus ⚠️.
- **`gemini-4-argon-cyber-permissive`** is an allowlist-only variant for defensive security.
- Google says it beats GPT-6 Astra and Claude Fable/Opus on benchmarks. These results are **self-reported**.

### Ecosystem
- Gemini app (web, Android, iOS), **Gemini in Android** (it replaced Assistant), **Gemini in Workspace** (Gmail, Docs, Sheets), Chrome, Search **AI Mode / AI Overviews**, NotebookLM, Veo (video), Imagen / "Nano Banana" (images), Gemini Live (voice/camera), Deep Research, and Gems (custom assistants).
- Google also supplies the technology behind **Apple's Siri** (see §2).
- **Plans:** Free, Google AI Plus, AI Pro, AI Ultra.

---

## 4. OpenAI ChatGPT

### History
- **30 Nov 2022:** ChatGPT launched as a research preview (GPT-3.5).
- **2023:** ChatGPT Plus (Feb), GPT-4 (Mar), plugins, then GPTs.
- **2024:** GPT-4o (May), o1 reasoning models (Sep), Canvas, ChatGPT Search, Advanced Voice, Pro at $200 (Dec), Sora (Dec).
- **2025:** Operator (Jan), Deep Research (Feb), Codex (May), ChatGPT Agent (Jul), **GPT-5** (7 Aug), Sora 2 (30 Sep), GPT-5.2 (Dec).
- **2026:** ChatGPT Go at $8 worldwide (Jan), GPT-5.3-Codex and the Codex Mac app (Feb), $122B funding round at an $852B valuation (Mar), GPT-5.4 (Mar), GPT-5.5 (Apr), Images 2.0 (Apr), confidential **IPO filing** (8 Jun), **ChatGPT Work** (9 Jul), GPT-Live voice (Jul), **GPT-6 Astra** (3 Sep), GPT-6 Sol & Luna (22 Sep), GPT-6.1 Sol (29 Sep), GPT-6 with Intelligent UI (7 Oct), GPT-Live-1.1 (15 Oct), Decisions API GA (22 Oct), **GPT-6.1 Terra** (26 Oct).

### Current model line-up (Oct 2026)
- **GPT-6 Astra:** most capable. Handles computer use, software engineering and professional work.
- **GPT-6.1 Sol:** coding and work model (ChatGPT Work, Codex, API).
- **GPT-6 Sol / GPT-6 Luna:** everyday Chat models. Luna is faster and cheaper, and free users get it.
- **GPT-6.1 Terra (26 Oct):** `gpt-6.1-terra`, priced at $1 / $5 per 1M tokens (half of Sol). Handles visual reasoning, computer use and writing. Available in the API, ChatGPT Work and Codex, but not on the Free tier.
- Specialist models: GPT-5.6-Cyber, GPT-Rosalind (life sciences), **Images 2.5**, **GPT-Live-1.1** (voice), **Sora 2** (video).
- ⚠️ Sources disagree on which model is the "default ChatGPT engine". OpenAI's own notes say GPT-6 Sol/Luna replaced GPT-5.6 Sol/Luna.

### Products & plans
- **Features:** Chat, Intelligent UI (interactive answers), Voice, Images, Sora, Deep Research, Agent, **ChatGPT Work** (always-on agents), **Codex** (coding agent: CLI, IDE, Mac app), Projects, Memory, GPTs, Health, Finances (US).
- **Plans:** Free · **Go $8** · Plus · **Pro $100 / $200** · **Pro 500 $500** (Sep 2026) · Business / Enterprise / Edu.
- **Developer:** OpenAI API, Responses / **Agents API** (beta, Sep 2026), Realtime / GPT-Live API.
- **Scale:** ~900M weekly users in Feb 2026, reportedly nearing **1B weekly** by mid-2026 ⚠️. Over 2M business customers.

---

## 5. Anthropic Claude

### Company
- Founded in **2021** by former OpenAI researchers, including CEO **Dario Amodei** and President **Daniela Amodei**. It is a public benefit corporation focused on AI safety (Constitutional AI, Responsible Scaling Policy). Major backers include Amazon and Google. IPO preparations have been reported ⚠️.

### Model history
- **2023:** Claude 1 (Mar), Claude 2 (Jul).
- **2024:** Claude 3 family (Haiku/Sonnet/Opus, Mar), Claude 3.5 Sonnet (Jun), computer use (Oct).
- **2025:** Claude 3.7 Sonnet + **Claude Code** (Feb), **Claude 4** (Opus 4 / Sonnet 4, May), Opus 4.1, Sonnet 4.5, Haiku 4.5 (Oct), Opus 4.5 (Nov).
- **2026:** Sonnet 4.6 (Feb), Opus 4.6, Opus 4.7 (Apr), **Claude Fable 5** (Jun, the first public "Mythos-class" model), Sonnet 5 (30 Jun), Opus 5, **Fable 5.1 + Mythos 5.1** (1 Sep), **Opus 5.5** (22 Sep), **Sonnet 5.5** (28 Sep), **Haiku 5.5** (7 Oct).

### Current line-up (Oct 2026)
| Model | API ID | Role | API price (in/out per 1M) |
|---|---|---|---|
| **Fable 5.1** | `claude-fable-5-1` | Most capable generally available model; heavy reasoning | ~$10 / $50 ⚠️ |
| **Mythos 5.1** | n/a | Restricted trusted-access program (e.g., defensive cyber) | n/a |
| **Opus 5.5** | `claude-opus-5-5` | Near-Fable quality; long-running agentic coding and knowledge work; 1M context, 128K output | $4 / $20 ⚠️ |
| **Sonnet 5.5** | `claude-sonnet-5-5` | Balanced default; ~30% faster than Sonnet 5 | $2 / $10 ⚠️ |
| **Haiku 5.5** | `claude-haiku-5-5` | Fast and cheap; beats Haiku 4.5 at ~75% lower cost | see Anthropic pricing |

### Products
- **Claude apps:** web, desktop (Mac/Windows), iOS, Android. Includes Projects, **Artifacts** (shareable pages and apps), Memory, web search, Research, and connectors (MCP: Google Drive, Slack, Notion, etc.).
- **Claude Code:** agentic coding tool for the CLI, VS Code / JetBrains, desktop and web (claude.ai/code). Supports skills, hooks, subagents, plugins and **Mods** (Oct 2026).
- **Cowork:** Claude doing knowledge work on your desktop and files.
- **Claude in Chrome:** browser agent, generally available Aug 2026.
- **Developer platform:** Claude API (Messages, tool use, prompt caching, batch), **Claude Agent SDK**, **MCP** (Model Context Protocol, the open standard Anthropic created), and Managed Agents. Also available on AWS Bedrock, Google Vertex AI and Microsoft Azure.
- **Plans:** Free · Pro · Max · Team · Enterprise.
- **Known for:** top-tier coding and agentic performance, very long context, careful writing, and safety research.

---

## 6. Other notable assistants

| Assistant | Maker | Positioning |
|---|---|---|
| **Microsoft Copilot** | Microsoft | Built into Windows and Microsoft 365. Uses OpenAI and in-house (MAI) models, plus Anthropic models in M365. |
| **Grok** | xAI (Elon Musk) | Real-time X/Twitter data, less filtered style. Grok 4.x line ⚠️. |
| **Meta AI** | Meta | Free inside WhatsApp, Instagram, Messenger and Ray-Ban Meta glasses. Llama-based models. |
| **Perplexity** | Perplexity AI | "Answer engine" with cited web search and the Comet browser. |
| **DeepSeek** | DeepSeek (China) | Low-cost, open-weight reasoning models (V3 / R-series). |
| **Amazon Alexa+** | Amazon | Generative Alexa for Echo devices. Partly uses Anthropic Claude. |
| **Mistral Le Chat** | Mistral AI (France) | European, open-weight-friendly option. |
| **Samsung Galaxy AI / Bixby** | Samsung | Phone features, largely powered by Gemini. |

---

## 7. Key industry dynamics (2026)
1. **Frontier race:** GPT-6 (OpenAI), Gemini 4 Argon (Google) and Claude Fable 5.1 / Opus 5.5 (Anthropic) all arrived within about six weeks (Sep–Oct 2026).
2. **Price war:** each new generation is cheaper per token (Opus 5.5 is 20% cheaper than Opus 5, Terra is half the price of Sol, and Haiku 5.5 is about 75% cheaper than Haiku 4.5).
3. **Agents everywhere:** computer use, browser agents (Claude in Chrome, ChatGPT Agent), coding agents (Claude Code, Codex, Antigravity) and always-on work agents.
4. **Restricted "cyber" tiers:** Mythos 5.1, Gemini 4 Argon Cyber and GPT-5.6-Cyber are released only to vetted defenders.
5. **Platform partnerships:** Apple uses Gemini for Siri, Microsoft mixes OpenAI and Anthropic, and Amazon uses Claude for Alexa+.
6. **Interoperability:** MCP (from Anthropic) has become the common standard for connecting assistants to tools and data.
7. **Money:** OpenAI is valued at about $852B and has filed confidentially for an IPO. Anthropic IPO preparations have been reported.

---

## 8. Which one should I use?
- **iPhone user who wants hands-free control of the phone and personal data:** Siri AI (iPhone 15 Pro+).
- **Heavy Google / Android / Workspace user:** Gemini.
- **Widest all-round consumer features (voice, images, video, huge community):** ChatGPT.
- **Coding, long documents, agentic work, careful reasoning:** Claude (Claude Code for developers).
- **Cited research:** Perplexity. **Microsoft 365 work:** Copilot. **Cheapest open weights:** DeepSeek.

---

## Sources
- AppleInsider: iOS 27 is now available. https://appleinsider.com/articles/26/09/14/ios-27-is-now-available-with-big-changes-to-photos-and-siri
- MacRumors: iOS 27 roundup. https://www.macrumors.com/roundup/ios-27/
- Eastern Herald: iOS 27 Siri runs on Gemini. https://easternherald.com/2026/09/13/ios-27-siri-google-gemini-apple-launch/
- Tom's Guide: iOS 27 Extensions. https://www.tomsguide.com/phones/iphones/beyond-chatgpt-ios-27-extensions-will-reportedly-allow-siri-to-use-google-gemini-and-claude
- AppleInsider: new Siri in iOS 26.4. https://appleinsider.com/articles/26/01/25/new-siri-expected-to-finally-debut-in-ios-264-beta-shortly
- Google Blog: Introducing Gemini 4 Argon. https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-argon/
- Google Blog: Gemini 4 Argon in the Gemini app. https://blog.google/innovation-and-ai/products/gemini-app/gemini-4-argon-availability/
- Google Cloud docs: Gemini 4 Argon. https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/4-argon
- TechCrunch: Gemini 4 Argon. https://techcrunch.com/2026/09/30/google-releases-gemini-4-argon-called-its-most-powerful-model-yet/
- Google Blog: August 2026 AI updates. https://blog.google/innovation-and-ai/technology/google-ai-updates-august-2026/
- OpenAI Model Release Notes. https://help.openai.com/en/articles/9624314-model-release-notes
- OpenAI Deployment Safety Hub: GPT-6 Sol/Luna. https://deploymentsafety.openai.com/gpt-6-october
- 9to5Mac: GPT-6.1 Terra. https://9to5mac.com/2026/10/26/openai-upgrades-chatgpt-and-codex-with-new-gpt-6-1-terra-model/
- ScriptByAI: ChatGPT timeline. https://www.scriptbyai.com/timeline-of-chatgpt/
- Bloomberg Law: OpenAI 1B users. https://news.bloomberglaw.com/artificial-intelligence/openai-has-more-than-1-billion-users-2-million-businesses
- DeepLearning.AI The Batch: Claude 5.5 family. https://www.deeplearning.ai/the-batch/claude-fills-out-its-model-family
- Yahoo Finance: Haiku 5.5. https://finance.yahoo.com/technology/article/anthropic-reveals-haiku-55-model-as-ai-pricing-war-intensifies-180000423.html
- Claude lineup Oct 2026 (blog). https://hassannazir.dev/blogs/anthropic-claude-models-october-2026-lineup-roadmap
- ClaudeWorld: Fable 5.1 & Claude 5.5. https://claude-world.com/articles/claude-fable-5-1-and-claude-5-5-family/
- Comparison roundups: https://brandedagency.com/blog/chatgpt-vs-gemini-vs-claude-vs-perplexity-2026 · https://www.ai-toolbox.co/alternatives-to-grok/best-alternatives-to-grok-2026

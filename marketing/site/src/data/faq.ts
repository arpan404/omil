// The questions on the page. The same list feeds the FAQ section, the FAQ structured data and
// /llms.txt, so the three never disagree. Keep the answers in line with the repository README.
export const faqs = [
  {
    q: "Is it really free?",
    a: "Yes. There is no account, no trial and no paid plan. Omil runs on your own Mac, so there is nothing to charge for.",
  },
  {
    q: "What do I need?",
    a: "An Apple silicon Mac with macOS 14 or later. On first launch Omil sets up its speech tools and downloads what it needs to run offline.",
  },
  {
    q: "Which languages does it understand?",
    a: "English, for now.",
  },
  {
    q: "Does my audio go anywhere?",
    a: "No. Recording, recognition and cleanup all happen on your Mac. An internet connection is only needed for the first setup and for updates.",
  },
  {
    q: "Which apps does it work in?",
    a: "Any app with a text field. Omil types into the field you were using, with your permission through Accessibility.",
  },
  {
    q: "Can I change how it cleans up?",
    a: "Yes. Switch between Clean and Verbatim at any time, add dictionary words and snippets, or edit the cleanup prompt itself.",
  },
  {
    q: "How is it different from Wispr Flow?",
    a: "It does the same job: hold a key, speak, and clean text is typed for you. The difference is that Omil runs on your Mac, needs no account and costs nothing.",
  },
  {
    q: "What about iPhone and iPad?",
    a: "Coming soon. The Omil keyboard sends your dictation to your Mac for transcription, so it stays free and private too.",
  },
];

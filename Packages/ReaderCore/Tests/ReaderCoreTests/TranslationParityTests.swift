import Foundation
import Testing

@testable import ReaderCore

private func translationFixture() throws -> [String: Any] {
  guard let url = Bundle.module.url(
    forResource: "Fixtures/translation/translation-fixtures",
    withExtension: "json"
  ) else {
    throw CocoaError(.fileNoSuchFile)
  }
  return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

private func fixtureJSON(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func messageFromFixture(_ value: Any) -> TranslationMessage {
  let object = value as! [String: Any]
  return TranslationMessage(
    role: object["role"] as? String ?? "user",
    content: object["content"] as! String
  )
}

@Test
func translationPureFunctionsMatchDesktopFixture() throws {
  let fixture = try translationFixture()

  let languages = fixture["languages"] as! [String: Any]
  let customCodes = languages["custom"] as! [String]
  #expect(customCodes.map(isCustomLanguageCode) == [true, true, true, false, false, false, false])

  for value in languages["support"] as! [[String: Any]] {
    let engine = value["engine"] as! String
    let language = value["language"] as! String
    #expect(isTranslationLanguageSupported(engine, language) == value["supported"] as! Bool)
  }
  for value in languages["normalized"] as! [[String: Any]] {
    let engine = value["engine"] as! String
    let language = value["language"] as! String
    let fallback = value["fallback"] as! String
    #expect(normalizeTranslationLanguage(engine, language, fallback) == value["output"] as! String)
  }
  for kernel in languages["kernels"] as! [[String: Any]] {
    let engine = kernel["engine"] as! String
    #expect(translationLanguagesForKernel(engine) == kernel["target"] as! [String])
    #expect(translationLanguagesForKernel(engine, direction: "source") == kernel["source"] as! [String])
  }

  let glossaryFixture = fixture["glossary"] as! [String: Any]
  let libraries = [
    GlossaryLibrary(
      id: "a",
      name: "Research",
      enabled: true,
      entries: [
        GlossaryEntry(source: "effect", target: "效应"),
        GlossaryEntry(source: "treatment effect", target: "处理效应"),
        GlossaryEntry(source: "C++", target: "$&术语"),
      ]
    ),
    GlossaryLibrary(
      id: "disabled",
      name: "Disabled",
      enabled: false,
      entries: [GlossaryEntry(source: "effect", target: "错误")]
    ),
  ]
  let entries = glossaryEntries(libraries)
  #expect(entries == [
    GlossaryEntry(source: "treatment effect", target: "处理效应"),
    GlossaryEntry(source: "effect", target: "效应"),
    GlossaryEntry(source: "C++", target: "$&术语"),
  ])
  let protected = protectTerms(
    "treatment effect and effect; C++ PMRGLOSSARY0END",
    entries
  )
  #expect(protected.text == glossaryFixture["protected"] as! String)
  #expect(try protected.restore(protected.text) == glossaryFixture["restored"] as! String)

  let spacing = fixture["spacing"] as! [[String: Any]]
  for value in spacing {
    let input = value["input"] as! String
    #expect(translationSpacing(input) == value["output"] as! String)
    #expect(paragraphDisplayText(input) == value["display"] as! String)
  }
  let kernelSpacing = fixture["kernelSpacing"] as! [[String: Any]]
  for value in kernelSpacing {
    #expect(kernelTranslationSpacing(value["input"] as! String) == value["output"] as! String)
  }

  let placeholders = fixture["placeholders"] as! [[String: Any]]
  for value in placeholders {
    let input = value["input"] as! String
    #expect(hasRichTextPlaceholders(input) == value["has"] as! Bool)
    #expect(stripRichTextPlaceholders(input) == value["stripped"] as! String)
    #expect(hasUnparsedPlaceholders(input) == value["unparsed"] as! Bool)
  }
  #expect(FormulaPlaceholderCodec.encode("x", id: 0) == "{v0}")
  #expect(FormulaPlaceholderCodec.decode("A {{v0}} B", formulas: ["FORMULA"], sourceInput: "{{v0}}") == "A FORMULA B")
  for value in fixture["formulaPlaceholders"] as! [[String: Any]] {
    let decoded = FormulaPlaceholderCodec.decode(
      value["translation"] as! String,
      formulas: value["formulaTexts"] as! [String],
      sourceInput: value["sourceInput"] as! String,
      fallbackText: value["text"] as? String
    )
    let expected = value["output"] as! String
    #expect(decoded == expected)
  }
}

@Test
func translationProviderBodiesAndCacheKeysMatchDesktopFixture() throws {
  let fixture = try translationFixture()
  let bodies = fixture["requestBodies"] as! [[String: Any]]

  let openAIInput = bodies[0]["input"] as! [String: Any]
  let openAIMessages = (openAIInput["messages"] as! [Any]).map(messageFromFixture)
  let openAIRequest = TranslationProviderRequest(
    model: openAIInput["model"] as? String,
    messages: openAIMessages,
    extra: ["response_format": .object(["type": .string("text")])]
  )
  let openAI = try OpenAICompatibleProvider(
    baseURL: URL(string: "https://example.test/v1")!,
    apiKey: "fixture-key",
    model: "gpt-4.1-mini"
  )
  #expect(try fixtureJSON(openAI.requestBody(for: openAIRequest)) == fixtureJSON(bodies[0]["completionBody"]!))

  let freeInput = bodies[1]["input"] as! [String: Any]
  let freeRequest = TranslationProviderRequest(
    messages: (freeInput["messages"] as! [Any]).map(messageFromFixture)
  )
  let free = SiliconFlowFreeProvider(language: "Simplified Chinese", endpoints: [])
  #expect(try fixtureJSON(free.requestBody(for: freeRequest)) == fixtureJSON(bodies[1]["completionBody"]!))

  let fastInput = bodies[2]["input"] as! [String: Any]
  let fastRequest = TranslationProviderRequest(
    messages: (fastInput["messages"] as! [Any]).map(messageFromFixture)
  )
  let fast = SiliconFlowFreeProvider(language: "zh", kernel: "pdf_math_fast", endpoints: [])
  #expect(try fixtureJSON(fast.requestBody(for: fastRequest)) == fixtureJSON(bodies[2]["completionBody"]!))

  let cacheKeys = fixture["cacheKeys"] as! [String: String]
  let exactKey = try TranslationCacheKey.paragraph(
    text: "Energy {v0} 中文",
    language: "Simplified Chinese",
    sourceLanguage: "French",
    model: "gpt-4.1-mini",
    serviceIdentity: [
      "service": "openai",
      "baseUrl": "https://example.test/v1",
      "model": "gpt-4.1-mini",
    ],
    glossary: [GlossaryEntry(source: "Energy", target: "能量")],
    cacheScope: "documenthash:3"
  )
  let compatibleKey = try TranslationCacheKey.compatibleParagraph(
    text: "Energy {v0} 中文",
    language: "Simplified Chinese",
    sourceLanguage: "French",
    glossary: [GlossaryEntry(source: "Energy", target: "能量")],
    cacheScope: "documenthash:3"
  )
  let providerKey = try TranslationCacheKey.provider(
    service: "openai",
    baseURL: "https://example.test/v1",
    model: "gpt-4.1-mini",
    body: openAI.requestBody(for: openAIRequest),
    cacheScope: "documenthash:3"
  )
  #expect(exactKey == cacheKeys["paragraph"])
  #expect(compatibleKey == cacheKeys["compatibleParagraph"])
  #expect(providerKey == cacheKeys["provider"])
}

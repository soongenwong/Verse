import SwiftUI

// No changes to APIKeyManager, LoadingState, Codable Models, or Enums.
// The existing flexible models with optional properties are still essential.
struct APIKeyManager {
    static func getGroqAPIKey() -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let key = dict["GroqAPIKey"] as? String else {
            print("ERROR: Could not find Secrets.plist or 'GroqAPIKey' key in it. Please follow setup instructions.")
            return nil
        }
        return key
    }
}
enum LoadingState: Equatable { case idle, loading, success(VerseAnalysis), error(String) }
struct VerseAnalysis: Codable, Identifiable, Equatable {
    var id: String { verseReference ?? UUID().uuidString }
    let verseReference: String?, verseText: String?, context: String?, exegesis: String?, themes: String?, crossReferences: [CrossReference]?
    enum CodingKeys: String, CodingKey {
        case verseReference = "verse_reference", verseText = "verse_text", context, exegesis, themes, crossReferences = "cross_references"
    }
}
struct CrossReference: Codable, Identifiable, Equatable { let id = UUID(); let reference: String?, text: String? }
struct GroqRequestBody: Codable { let messages: [GroqMessage], model: String, temperature: Double = 0.5, max_tokens: Int = 2048, top_p: Double = 1, stop: String? = nil, stream: Bool = false }
struct GroqResponse: Codable { let choices: [GroqChoice] }
struct GroqChoice: Codable { let message: GroqMessage }
struct GroqMessage: Codable { let role: String, content: String }
enum AnalysisTab: String, CaseIterable, Identifiable {
    case context = "Context", exegesis = "Exegesis", themes = "Themes", crossRef = "Cross-Ref"
    var id: String { self.rawValue }
}


// MARK: - Main View
struct VerseView: View {
    
    @State private var verseInput: String = "Psalm 34:9"
    @State private var loadingState: LoadingState = .idle
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Input Section (no changes)
                HStack {
                    TextField("Enter a verse (e.g., Romans 8:28)", text: $verseInput)
                        .font(.title3) // MODIFIED: Larger font for the text field
                        .padding(.vertical, 12) // MODIFIED: Increase vertical padding
                        .padding(.horizontal)
                        .background(Color(.systemGray6))
                        .cornerRadius(15) // MODIFIED: More rounded corners
                        .onSubmit { analyzeVerse() }
                    
                    Button(action: analyzeVerse) {
                        // Show progress indicator inside button when loading
                        if case .loading = loadingState {
                            ProgressView().tint(.white)
                        } else {
                            Text("Analyze")
                            .font(.title3)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(verseInput.trimmingCharacters(in: .whitespaces).isEmpty || (loadingState == .loading))
                }
                .padding()
                
                Divider()
                
                // Dynamic Content Area (no changes)
                switch loadingState {
                case .idle:
                    VStack { Spacer(); Image(systemName: "text.book.closed").font(.largeTitle).foregroundColor(.secondary); Text("Enter a verse and tap 'Analyze' to begin.").foregroundColor(.secondary).padding(.top); Spacer() }
                case .loading:
                    VStack { Spacer(); ProgressView("Generating Analysis..."); Spacer() }
                case .success(let analysis):
                    AnalysisDetailView(analysis: analysis)
                case .error(let errorMessage):
                    VStack(spacing: 15) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundColor(.orange)
                        Text("Analysis Failed").font(.headline)
                        Text(errorMessage).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                        Button("Try Again", action: analyzeVerse).buttonStyle(.bordered)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Verse Explorer")
            .navigationBarTitleDisplayMode(.large)
        }
    }
    
    func analyzeVerse() {
        // Helper to avoid duplicating the task logic
        Task {
            await generateAnalysis()
        }
    }
    
    // MARK: - Networking Function (MAJOR CHANGES)
    private func generateAnalysis() async {
        guard let apiKey = APIKeyManager.getGroqAPIKey() else {
            await MainActor.run { self.loadingState = .error("API Key not found.") }
            return
        }
        
        // Hide keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        await MainActor.run { self.loadingState = .loading }
        
        // MARK: - FIX #1: The Ultimate Prompt
        // This is now extremely specific about the most common failure points.
        let systemPrompt = """
        You are a biblical analysis expert. Your task is to generate a multi-layered analysis for a given Bible verse.
        Your response MUST be ONLY a single, valid JSON object.
        DO NOT include any introductory text, explanations, apologies, or markdown formatting like ```json. Your response must start with `{` and end with `}`.

        CRITICAL JSON FORMATTING RULES:
        1.  Structure: Adhere strictly to the specified JSON structure. If a value isn't available, use an empty string "" or an empty array [].
        2.  Escaping Quotes: You MUST properly escape any double quotes (") that appear inside a JSON string value with a backslash (\\"). For example, if a verse text is `He said, "Follow me."`, the JSON value must be `"He said, \\"Follow me.\\""`. This is the most important rule.
        3.  No Trailing Commas: Do not include a comma after the last element in an object or array.

        Here is the required JSON structure:
        {
          "verse_reference": "string",
          "verse_text": "string",
          "context": "string",
          "exegesis": "string",
          "themes": "string",
          "cross_references": [
            { "reference": "string", "text": "string" }
          ]
        }
        """

        let requestBody = GroqRequestBody(
            messages: [
                GroqMessage(role: "system", content: systemPrompt),
                GroqMessage(role: "user", content: "Generate the analysis for: \(verseInput)")
            ],
            model: "llama3-8b-8192"
        )
        
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            await MainActor.run { self.loadingState = .error("Invalid API URL.") }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            
            let (data, _) = try await URLSession.shared.data(for: request)
            let groqResponse = try JSONDecoder().decode(GroqResponse.self, from: data)
            
            guard let contentString = groqResponse.choices.first?.message.content else {
                throw URLError(.cannotParseResponse)
            }
            
            // --- FOR DEBUGGING ---
            print("--- RAW AI RESPONSE ---\n\(contentString)\n-----------------------")
            
            // MARK: - FIX #2: Sanitize and Extract JSON
            // This robustly cleans the AI's output before decoding.
            let sanitizedString = sanitize(jsonString: contentString)
            
            print("--- SANITIZED JSON ---\n\(sanitizedString)\n----------------------")
            
            guard let jsonData = sanitizedString.data(using: .utf8) else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Failed to convert sanitized string to data."])
            }
            
            let finalAnalysis = try JSONDecoder().decode(VerseAnalysis.self, from: jsonData)
            
            await MainActor.run { self.loadingState = .success(finalAnalysis) }
            
        } catch {
            await MainActor.run {
                // MARK: - FIX #3: Better User-Facing Error Message
                let userFriendlyError = """
                The AI's response for this verse was not structured correctly.
                This can sometimes happen with verses containing complex punctuation.
                
                Error Details: \(error.localizedDescription)
                """
                self.loadingState = .error(userFriendlyError)
            }
        }
    }
    
    /// Pre-processes the AI's string response to fix common JSON errors before decoding.
    private func sanitize(jsonString: String) -> String {
        var correctedString = jsonString
        
        // 1. Extract content between the first '{' and the last '}'
        if let startRange = correctedString.range(of: "{"),
           let endRange = correctedString.range(of: "}", options: .backwards) {
            correctedString = String(correctedString[startRange.lowerBound...endRange.lowerBound])
        } else {
            // If we can't even find braces, return the broken string to let it fail loudly
            return jsonString
        }
        
        // 2. Remove trailing commas from objects and arrays, a very common LLM error
        // e.g., "key": "value", } -> "key": "value" }
        correctedString = correctedString.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        
        return correctedString
    }
}


// MARK: - Subviews (Updated to be more resilient)
struct AnalysisDetailView: View {
    let analysis: VerseAnalysis
    @State private var selectedTab: AnalysisTab = .context

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(analysis.verseReference ?? "Unknown Reference")
                    .font(.largeTitle).fontWeight(.bold)
                Text("\"\(analysis.verseText ?? "No text provided.")\"")
                    .font(.title3).italic().foregroundColor(.secondary)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading).background(Color(.systemGray6))

            Picker("Analysis Lens", selection: $selectedTab.animation(.easeInOut)) {
                ForEach(AnalysisTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented).padding()

            ScrollView {
                contentForSelectedTab().padding([.horizontal, .bottom])
            }
            .frame(maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func contentForSelectedTab() -> some View {
        switch selectedTab {
        case .context:
            AnalysisTextView(title: "Historical & Literary Context", content: analysis.context ?? "No context provided.")
        case .exegesis:
            AnalysisTextView(title: "Exegesis (Direct Interpretation)", content: analysis.exegesis ?? "No exegesis provided.")
        case .themes:
            AnalysisTextView(title: "Theological Themes", content: analysis.themes ?? "No themes provided.")
        case .crossRef:
            CrossReferenceListView(title: "Illuminating Cross-References", references: analysis.crossReferences ?? [])
        }
    }
}

struct AnalysisTextView: View {
    let title: String, content: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundColor(.secondary)
            Text(content).font(.body).lineSpacing(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CrossReferenceListView: View {
    let title: String, references: [CrossReference]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundColor(.secondary)
            
            if references.isEmpty {
                Text("No cross-references were provided for this verse.")
                    .foregroundColor(.secondary).padding().frame(maxWidth: .infinity)
                    .background(Color(.systemGray5)).cornerRadius(8)
            } else {
                ForEach(references) { ref in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ref.reference ?? "N/A").fontWeight(.bold)
                        Text(ref.text ?? "...").font(.footnote).foregroundColor(.secondary)
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray5)).cornerRadius(8).padding(.bottom, 4)
                }
            }
        }
    }
}


// MARK: - Preview
struct VerseView_Previews: PreviewProvider { static var previews: some View { VerseView() } }


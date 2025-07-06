import SwiftUI

// No changes to APIKeyManager or LoadingState

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

enum LoadingState {
    case idle
    case loading
    case success(VerseAnalysis)
    case error(String)
}


// MARK: - FIX #1: Flexible Codable Models
// We make properties optional (?) to prevent crashes if the AI omits a key.
struct VerseAnalysis: Codable, Identifiable {
    var id: String { verseReference ?? UUID().uuidString }
    
    let verseReference: String?
    let verseText: String?
    let context: String?
    let exegesis: String?
    let themes: String?
    let crossReferences: [CrossReference]? // This can now be nil

    enum CodingKeys: String, CodingKey {
        case verseReference = "verse_reference"
        case verseText = "verse_text"
        case context
        case exegesis
        case themes
        case crossReferences = "cross_references"
    }
}

// Making this optional too, just in case.
struct CrossReference: Codable, Identifiable {
    let id = UUID()
    let reference: String?
    let text: String?
}

// No changes to Groq API models or AnalysisTab enum
struct GroqRequestBody: Codable {
    let messages: [GroqMessage]
    let model: String
    let temperature: Double = 0.5
    let max_tokens: Int = 2048
    let top_p: Double = 1
    let stop: String? = nil
    let stream: Bool = false
}
struct GroqResponse: Codable { let choices: [GroqChoice] }
struct GroqChoice: Codable { let message: GroqMessage }
struct GroqMessage: Codable { let role: String, content: String }
enum AnalysisTab: String, CaseIterable, Identifiable {
    case context = "Context", exegesis = "Exegesis", themes = "Themes", crossRef = "Cross-Ref"
    var id: String { self.rawValue }
}


// MARK: - Main View
struct VerseView: View {
    
    @State private var verseInput: String = "John 3:16"
    @State private var loadingState: LoadingState = .idle
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Input Section (no changes)
                HStack {
                    TextField("Enter a verse (e.g., Romans 8:28)", text: $verseInput)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Analyze") {
                        Task {
                            await generateAnalysis()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(verseInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
                
                Divider()
                
                // Dynamic Content Area (no changes)
                switch loadingState {
                case .idle:
                    VStack {
                        Spacer()
                        Image(systemName: "text.book.closed")
                            .font(.largeTitle).foregroundColor(.secondary)
                        Text("Enter a verse and tap 'Analyze' to begin.").foregroundColor(.secondary).padding(.top)
                        Spacer()
                    }
                case .loading:
                    VStack { Spacer(); ProgressView("Generating Analysis..."); Spacer() }
                case .success(let analysis):
                    AnalysisDetailView(analysis: analysis)
                case .error(let errorMessage):
                    VStack {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.red)
                        Text("An Error Occurred").font(.headline).padding(.top)
                        Text(errorMessage).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Verse Explorer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Networking Function (MAJOR CHANGES HERE)
    private func generateAnalysis() async {
        guard let apiKey = APIKeyManager.getGroqAPIKey() else {
            await MainActor.run { self.loadingState = .error("API Key not found.") }
            return
        }
        
        await MainActor.run { self.loadingState = .loading }
        
        // MARK: - FIX #2: A more demanding prompt
        let systemPrompt = """
        You are a biblical analysis expert. For the given verse, generate a multi-layered analysis.
        Your entire response MUST be ONLY the JSON object.
        DO NOT include any explanatory text, introduction, or markdown like ```json.
        The JSON object must have the following exact structure. If a value is not available, use an empty string "" or an empty array [].
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
            
            // --- FOR DEBUGGING: Print the raw response from the AI ---
            print("--- RAW AI RESPONSE ---")
            print(contentString)
            print("-----------------------")
            
            // MARK: - FIX #3: Robust JSON Extraction
            // This finds the JSON block even if it's surrounded by text or markdown
            guard let jsonData = extractJson(from: contentString) else {
                throw URLError(.cannotParseResponse)
            }
            
            let finalAnalysis = try JSONDecoder().decode(VerseAnalysis.self, from: jsonData)
            
            await MainActor.run { self.loadingState = .success(finalAnalysis) }
            
        } catch {
            await MainActor.run {
                // Provide a more helpful error message
                var errorMessage = "Failed to generate or parse analysis. Error: \(error.localizedDescription)"
                if let decodingError = error as? DecodingError {
                    errorMessage += "\n\nDecoding Error: \(decodingError)"
                }
                self.loadingState = .error(errorMessage)
            }
        }
    }
    
    /// Helper function to extract a JSON object from a string that might contain other text.
    private func extractJson(from string: String) -> Data? {
        // Find the first "{" and the last "}"
        guard let jsonStartRange = string.range(of: "{"),
              let jsonEndRange = string.range(of: "}", options: .backwards) else {
            return nil
        }
        
        let jsonSubstring = string[jsonStartRange.lowerBound...jsonEndRange.lowerBound]
        return Data(jsonSubstring.utf8)
    }
}


// MARK: - AnalysisDetailView (UI must now handle optional data)
struct AnalysisDetailView: View {
    let analysis: VerseAnalysis
    @State private var selectedTab: AnalysisTab = .context

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - FIX #4: Use nil-coalescing (??) to provide default values
            VStack(alignment: .leading, spacing: 10) {
                Text(analysis.verseReference ?? "Unknown Reference") // Provide default
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("\"\(analysis.verseText ?? "No text provided.")\"") // Provide default
                    .font(.title3)
                    .italic()
                    .foregroundColor(.secondary)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading).background(Color(.systemGray6))

            Picker("Analysis Lens", selection: $selectedTab.animation(.easeInOut)) {
                ForEach(AnalysisTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented).padding()

            ScrollView {
                contentForSelectedTab()
                    .padding(.horizontal)
                    .padding(.bottom)
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
            // Use `?? []` to handle a nil array gracefully
            CrossReferenceListView(title: "Illuminating Cross-References", references: analysis.crossReferences ?? [])
        }
    }
}


// MARK: - Reusable Subviews (Updated for optional data)
struct AnalysisTextView: View {
    let title: String
    let content: String // This will receive a non-optional string from the view above
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundColor(.secondary)
            Text(content).font(.body).lineSpacing(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CrossReferenceListView: View {
    let title: String
    let references: [CrossReference]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundColor(.secondary)
            
            // Check if the list is empty after handling the optional
            if references.isEmpty {
                Text("No cross-references were provided for this verse.")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray5))
                    .cornerRadius(8)
            } else {
                ForEach(references) { ref in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ref.reference ?? "N/A").fontWeight(.bold)
                        Text(ref.text ?? "...")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading).background(Color(.systemGray5)).cornerRadius(8).padding(.bottom, 4)
                }
            }
        }
    }
}


// MARK: - Preview
struct VerseView_Previews: PreviewProvider {
    static var previews: some View {
        VerseView()
    }
}

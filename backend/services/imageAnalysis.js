/**
 * AI image analysis - NOT IMPLEMENTED YET (intentionally).
 *
 * This is the single integration point. When you pick a model/provider:
 *   1. Implement analyze() below (read the file at `filePath`, call the model,
 *      return a plain JSON-serialisable object).
 *   2. Set `available` to true.
 * Nothing else in the backend or frontend needs to change - the route in
 * routes/images.js stores whatever analyze() returns in images.analysis_result.
 */
const available = false;

async function analyze(/* { filePath, mimeType, description } */) {
  throw new Error('Image analysis is not implemented yet');
}

module.exports = { available, analyze };

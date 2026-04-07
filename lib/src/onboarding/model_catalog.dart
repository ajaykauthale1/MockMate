class ModelEntry {
  final String id;
  final String vendor;
  final String license;
  final double vramGb;
  final bool freeForEnterprise;
  final String description;

  const ModelEntry({
    required this.id,
    required this.vendor,
    required this.license,
    required this.vramGb,
    required this.freeForEnterprise,
    this.description = '',
  });
}

const List<ModelEntry> kModelCatalog = [
  ModelEntry(
    id: 'gemma3:4b',
    vendor: 'Google',
    license: 'Apache 2.0',
    vramGb: 3.0,
    freeForEnterprise: true,
    description: 'Recommended — fast, 128 K context, Apache 2.0',
  ),
  ModelEntry(
    id: 'gemma3:12b',
    vendor: 'Google',
    license: 'Apache 2.0',
    vramGb: 8.0,
    freeForEnterprise: true,
    description: 'Better quality; needs 8 GB VRAM',
  ),
  ModelEntry(
    id: 'phi4-mini',
    vendor: 'Microsoft',
    license: 'MIT',
    vramGb: 3.5,
    freeForEnterprise: true,
    description: 'Compact, MIT licence',
  ),
  ModelEntry(
    id: 'qwen2.5:7b-instruct-q4_K_M',
    vendor: 'Alibaba',
    license: 'Apache 2.0',
    vramGb: 4.5,
    freeForEnterprise: true,
    description: '128 K context, great for long KBs',
  ),
  ModelEntry(
    id: 'mistral:7b',
    vendor: 'Mistral AI',
    license: 'Apache 2.0',
    vramGb: 4.5,
    freeForEnterprise: true,
    description: 'Strong general reasoning',
  ),
  ModelEntry(
    id: 'llama3.2:3b',
    vendor: 'Meta',
    license: 'Meta Community',
    vramGb: 2.5,
    freeForEnterprise: false,
    description: 'Lightest option — runs on 4 GB RAM',
  ),
];

export interface MarketAsset {
  symbol: string;
  name: string;
  price: number;
  change24h: number;
  volume: string;
  color: string;
}

export const marketData: MarketAsset[] = [
  { symbol: 'BTC', name: 'Bitcoin', price: 67234.50, change24h: 2.34, volume: '$28.4B', color: '#f7931a' },
  { symbol: 'ETH', name: 'Ethereum', price: 3512.80, change24h: 3.12, volume: '$14.2B', color: '#627eea' },
  { symbol: 'BNB', name: 'BNB', price: 589.30, change24h: -0.87, volume: '$2.1B', color: '#f3ba2f' },
  { symbol: 'SOL', name: 'Solana', price: 178.45, change24h: 5.67, volume: '$4.8B', color: '#9945ff' },
  { symbol: 'XRP', name: 'XRP', price: 0.6234, change24h: 1.45, volume: '$1.9B', color: '#23292f' },
  { symbol: 'ADA', name: 'Cardano', price: 0.4567, change24h: -2.13, volume: '$890M', color: '#0033ad' },
  { symbol: 'DOGE', name: 'Dogecoin', price: 0.1342, change24h: 4.23, volume: '$1.2B', color: '#c2a633' },
  { symbol: 'DOT', name: 'Polkadot', price: 7.89, change24h: 0.92, volume: '$620M', color: '#e6007a' },
  { symbol: 'AVAX', name: 'Avalanche', price: 42.15, change24h: -1.34, volume: '$780M', color: '#e84142' },
];

export const dashboardMarketData: MarketAsset[] = [
  { symbol: 'BTC', name: 'Bitcoin', price: 67234.50, change24h: 2.34, volume: '$28.4B', color: '#f7931a' },
  { symbol: 'ETH', name: 'Ethereum', price: 3512.80, change24h: 3.12, volume: '$14.2B', color: '#627eea' },
  { symbol: 'BNB', name: 'BNB', price: 589.30, change24h: -0.87, volume: '$2.1B', color: '#f3ba2f' },
  { symbol: 'SOL', name: 'Solana', price: 178.45, change24h: 5.67, volume: '$4.8B', color: '#9945ff' },
  { symbol: 'XRP', name: 'XRP', price: 0.6234, change24h: 1.45, volume: '$1.9B', color: '#23292f' },
  { symbol: 'ADA', name: 'Cardano', price: 0.4567, change24h: -2.13, volume: '$890M', color: '#0033ad' },
  { symbol: 'DOGE', name: 'Dogecoin', price: 0.1342, change24h: 4.23, volume: '$1.2B', color: '#c2a633' },
  { symbol: 'DOT', name: 'Polkadot', price: 7.89, change24h: 0.92, volume: '$620M', color: '#e6007a' },
  { symbol: 'MATIC', name: 'Polygon', price: 0.8923, change24h: 1.78, volume: '$450M', color: '#8247e5' },
  { symbol: 'AVAX', name: 'Avalanche', price: 42.15, change24h: -1.34, volume: '$780M', color: '#e84142' },
  { symbol: 'LINK', name: 'Chainlink', price: 18.42, change24h: 3.45, volume: '$680M', color: '#2a5ada' },
  { symbol: 'UNI', name: 'Uniswap', price: 9.87, change24h: -0.56, volume: '$320M', color: '#ff007a' },
  { symbol: 'LTC', name: 'Litecoin', price: 84.50, change24h: 1.12, volume: '$540M', color: '#345d9d' },
];

export const statsData = [
  { label: 'Daily Volume', value: 8.4, suffix: 'B', prefix: '$' },
  { label: 'Platform Uptime', value: 99.99, suffix: '%', prefix: '' },
  { label: 'Registered Users', value: 5.2, suffix: 'M', prefix: '' },
  { label: 'Countries Served', value: 190, suffix: '+', prefix: '' },
];

export const trustCards = [
  {
    icon: 'shield-check',
    title: 'Security Reviewed',
    value: 'SecureChain Labs',
    sub: '98% Security Score',
    description: 'Independently audited with a near-perfect security rating across all systems.',
  },
  {
    icon: 'users',
    title: 'Global Community',
    value: '5M+ Users',
    sub: 'Active Traders',
    description: 'A growing worldwide community of traders trust our platform every day.',
  },
  {
    icon: 'lock',
    title: 'Funds Protection',
    value: 'GuardianTrust',
    sub: 'Insurance Partner',
    description: 'User funds are backed by industry-leading insurance coverage for peace of mind.',
  },
  {
    icon: 'zap',
    title: 'Best Execution',
    value: '0.05%',
    sub: 'Taker Fee',
    description: 'Among the most competitive fee structures in the digital asset industry.',
  },
];

export const features = [
  {
    icon: 'zap',
    title: 'Lightning Execution',
    description: 'Orders matched in under 10 milliseconds with our high-performance matching engine.',
  },
  {
    icon: 'bar-chart',
    title: 'Advanced Charting',
    description: 'Professional-grade charts with 100+ indicators and real-time market data visualization.',
  },
  {
    icon: 'globe',
    title: '800+ Markets',
    description: 'Trade hundreds of spot and futures pairs across all major digital assets.',
  },
  {
    icon: 'earth',
    title: 'Global Availability',
    description: 'Accessible in 190+ countries with localized support and multi-language interfaces.',
  },
];

export const verifiedBy = [
  'SecureChain Labs',
  'GuardianTrust',
  'AuditForge',
  'CryptoShield',
];

export const howItWorks = [
  {
    icon: 'user-plus',
    title: 'Create Account',
    description: 'Sign up in minutes with a secure, streamlined verification process.',
  },
  {
    icon: 'credit-card',
    title: 'Deposit Funds',
    description: 'Add funds via bank transfer, card, or crypto deposit with zero hassle.',
  },
  {
    icon: 'trending-up',
    title: 'Start Trading',
    description: 'Access 800+ markets with professional tools and real-time data.',
  },
  {
    icon: 'arrow-down-to-line',
    title: 'Withdraw Anytime',
    description: 'Cash out your earnings quickly with flexible withdrawal options.',
  },
];

export const securityFeatures = [
  {
    icon: 'shield',
    title: 'Multi-Layered Security Framework',
    description: 'A comprehensive, defense-in-depth approach protecting every layer of the platform.',
  },
  {
    icon: 'eye',
    title: 'Regular Independent Reviews',
    description: 'Ongoing third-party assessments ensure our systems meet evolving security standards.',
  },
  {
    icon: 'lock-keyhole',
    title: 'Encrypted Cold Storage',
    description: 'The majority of user funds are held in offline, encrypted cold storage wallets.',
  },
  {
    icon: 'fingerprint',
    title: 'Advanced Authentication',
    description: 'Multi-factor authentication and withdrawal safeguards keep your account secure.',
  },
];

export const navLinks = [
  { label: 'Trading', href: '#markets' },
  { label: 'Security', href: '#security' },
  { label: 'Why Trust Us', href: '#trust' },
  { label: 'Compliance', href: '#compliance' },
];

export const footerColumns = [
  {
    title: 'Trading',
    links: ['Spot Trading', 'Futures', 'Margin', 'OTC Desk'],
  },
  {
    title: 'Security',
    links: ['Framework', 'Cold Storage', 'Audits', 'Insurance'],
  },
  {
    title: 'Company',
    links: ['About Us', 'Careers', 'Press', 'Blog'],
  },
  {
    title: 'Support',
    links: ['Help Center', 'API Docs', 'Status', 'Contact'],
  },
];

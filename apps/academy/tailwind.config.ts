import type { Config } from 'tailwindcss';

const withVar = (name: string) => `hsl(var(--${name}))`;

const config: Config = {
  darkMode: 'class',
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}', './lib/**/*.{ts,tsx}'],
  theme: {
    container: {
      center: true,
      padding: '2rem',
      screens: { '2xl': '1400px' },
    },
    extend: {
      colors: {
        border: withVar('border'),
        input: withVar('input'),
        ring: withVar('ring'),
        background: withVar('background'),
        foreground: withVar('foreground'),
        surface: withVar('surface'),
        primary: {
          DEFAULT: withVar('primary'),
          foreground: withVar('primary-foreground'),
          muted: withVar('primary-muted'),
        },
        secondary: {
          DEFAULT: withVar('secondary'),
          foreground: withVar('secondary-foreground'),
        },
        destructive: {
          DEFAULT: withVar('destructive'),
          foreground: withVar('destructive-foreground'),
          muted: withVar('destructive-muted'),
        },
        success: {
          DEFAULT: withVar('success'),
          foreground: withVar('success-foreground'),
          muted: withVar('success-muted'),
        },
        warning: {
          DEFAULT: withVar('warning'),
          foreground: withVar('warning-foreground'),
          muted: withVar('warning-muted'),
        },
        info: {
          DEFAULT: withVar('info'),
          foreground: withVar('info-foreground'),
          muted: withVar('info-muted'),
        },
        muted: {
          DEFAULT: withVar('muted'),
          foreground: withVar('muted-foreground'),
        },
        accent: {
          DEFAULT: withVar('accent'),
          foreground: withVar('accent-foreground'),
        },
        card: {
          DEFAULT: withVar('card'),
          foreground: withVar('card-foreground'),
        },
        popover: {
          DEFAULT: withVar('popover'),
          foreground: withVar('popover-foreground'),
        },
        sidebar: {
          DEFAULT: withVar('sidebar'),
          foreground: withVar('sidebar-foreground'),
          muted: withVar('sidebar-muted'),
          accent: withVar('sidebar-accent'),
          active: withVar('sidebar-active'),
          border: withVar('sidebar-border'),
        },
      },
      borderRadius: {
        lg: 'var(--radius)',
        md: 'calc(var(--radius) - 2px)',
        sm: 'calc(var(--radius) - 4px)',
      },
      boxShadow: {
        xs: '0 1px 2px 0 hsl(222 47% 11% / 0.05)',
        sm: '0 1px 3px 0 hsl(222 47% 11% / 0.08), 0 1px 2px -1px hsl(222 47% 11% / 0.06)',
        md: '0 4px 10px -2px hsl(222 47% 11% / 0.08), 0 2px 6px -2px hsl(222 47% 11% / 0.05)',
        lg: '0 12px 28px -6px hsl(222 47% 11% / 0.12), 0 4px 10px -4px hsl(222 47% 11% / 0.06)',
      },
      keyframes: {
        'fade-in': {
          from: { opacity: '0' },
          to: { opacity: '1' },
        },
        'slide-in-left': {
          from: { transform: 'translateX(-100%)' },
          to: { transform: 'translateX(0)' },
        },
        shimmer: {
          '100%': { transform: 'translateX(100%)' },
        },
      },
      animation: {
        'fade-in': 'fade-in 150ms ease-out',
        'slide-in-left': 'slide-in-left 180ms ease-out',
        shimmer: 'shimmer 1.6s infinite',
      },
    },
  },
  plugins: [require('tailwindcss-animate')],
};

export default config;

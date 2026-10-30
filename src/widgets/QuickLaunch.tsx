import { AccessoryWidgetBackground, Image, Spacer, Text, VStack, ZStack } from '@expo/ui/swift-ui';
import { containerBackground, font, foregroundStyle, frame } from '@expo/ui/swift-ui/modifiers';
import { createWidget, type WidgetEnvironment } from 'expo-widgets';

export type QuickLaunchProps = {
  /** Uygulamanın adı ve alt yazı, uygulamanın dilinde (uygulama her açılışta günceller). */
  title: string;
  subtitle: string;
};

/**
 * Ana ekran (küçük) ve kilit ekranı (yuvarlak) widget'ı: dokununca uygulamayı açar. İkonla aynı sarı
 * zemin ve video kamerası simgesi. Widget'ın kendi ortamında çalışır: dışarıdaki sabitlere ve
 * uygulamanın durumuna erişemez, her şey burada ya da `props` ile gelir.
 */
const QuickLaunch = (props: QuickLaunchProps, environment: WidgetEnvironment) => {
  'widget';
  const ink = '#15151A';
  if (environment.widgetFamily === 'accessoryCircular') {
    // iOS her widget'ta arka plan ister; yoksa "Please adopt containerBackground API" yazar. Kilit
    // ekranında sistem bunu kaldırır, yuvarlak zemini AccessoryWidgetBackground verir.
    return (
      <ZStack modifiers={[containerBackground('#00000000', 'widget')]}>
        <AccessoryWidgetBackground />
        <Image systemName="video.fill" size={22} />
      </ZStack>
    );
  }
  // Uygulama henüz açılmadıysa props boş olabilir.
  const title = props?.title ?? 'Dual Camera';
  const subtitle = props?.subtitle ?? 'Open camera';
  return (
    <VStack
      alignment="leading"
      spacing={2}
      // maxWidth/maxHeight widget'tan büyük: tüm alanı kaplar, içerik sol üstten başlar.
      modifiers={[frame({ maxWidth: 1000, maxHeight: 1000, alignment: 'topLeading' }), containerBackground('#FACC15', 'widget')]}
    >
      <Image systemName="video.fill" size={40} color={ink} />
      <Spacer />
      <Text modifiers={[font({ size: 17, weight: 'bold' }), foregroundStyle(ink)]}>{title}</Text>
      {/* #AARRGGBB: %70 opak */}
      <Text modifiers={[font({ size: 13, weight: 'medium' }), foregroundStyle('#B315151A')]}>{subtitle}</Text>
    </VStack>
  );
};

export default createWidget('QuickLaunch', QuickLaunch);

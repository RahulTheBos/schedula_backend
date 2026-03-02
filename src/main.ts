import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
    const app = await NestFactory.create(AppModule);

    // Global API prefix – all routes will be /api/v1/...
    app.setGlobalPrefix('api/v1');

    const port = process.env.PORT ?? 3000;
    await app.listen(port);

    console.log(`🚀 Pearl API is running on: http://localhost:${port}/api/v1`);
}

bootstrap();

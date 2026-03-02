import { Injectable } from '@nestjs/common';

@Injectable()
export class AppService {
    getRoot(): { message: string } {
        return { message: 'Pearl API is up and running 🚀' };
    }
}
